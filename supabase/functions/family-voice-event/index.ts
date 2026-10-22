const ALLOWED_ORIGINS = new Set([
  "https://keversthomas-lang.github.io",
  "http://127.0.0.1:9000",
  "http://localhost:9000",
]);
const MAX_AUDIO_BYTES = 5 * 1024 * 1024;

function corsHeaders(origin) {
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGINS.has(origin) ? origin : "null",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
function jsonResponse(body, status, origin) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(origin), "Content-Type": "application/json" },
  });
}
function parseOutputText(response) {
  if (typeof response.output_text === "string") return response.output_text;
  for (const item of response.output || []) {
    for (const part of item.content || []) {
      if (part.type === "output_text" && typeof part.text === "string") return part.text;
    }
  }
  return "";
}

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") || "";
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(origin) });
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed." }, 405, origin);
  if (!ALLOWED_ORIGINS.has(origin)) return jsonResponse({ error: "Origin not allowed." }, 403, origin);

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) return jsonResponse({ error: "Le secret OPENAI_API_KEY manque dans Supabase." }, 503, origin);

  try {
    const form = await req.formData();
    const token = String(form.get("token") || "");
    const audio = form.get("audio");
    const today = String(form.get("today") || "");
    const timezone = String(form.get("timezone") || "Europe/Berlin");
    const locale = String(form.get("locale") || "de-DE");

    if (!/^[A-Za-z0-9_-]{40,}$/.test(token)) return jsonResponse({ error: "Lien familial invalide." }, 401, origin);
    if (!(audio instanceof File) || audio.size === 0) return jsonResponse({ error: "Aucun enregistrement reçu." }, 400, origin);
    if (audio.size > MAX_AUDIO_BYTES) return jsonResponse({ error: "Enregistrement trop long. Limite : 5 Mo (environ 30 secondes)." }, 413, origin);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const publishableKey = req.headers.get("apikey") || "";
    if (!supabaseUrl || !publishableKey) return jsonResponse({ error: "Configuration Supabase incomplète." }, 503, origin);

    // The secret share token is the app's access control. Confirm it before using paid API credits.
    const calendarResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/shared_calendar_read`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: publishableKey, Authorization: `Bearer ${publishableKey}` },
      body: JSON.stringify({ p_token: token }),
    });
    if (!calendarResponse.ok) return jsonResponse({ error: "Lien familial invalide ou expiré." }, 401, origin);
    const calendar = await calendarResponse.json();
    const people = (calendar.profiles || []).map((profile) => String(profile.name || "").trim()).filter(Boolean);
    const allowedPeople = [...new Set(["Alle", ...people])];

    const transcriptionForm = new FormData();
    transcriptionForm.set("file", audio, audio.name || "family-appointment.webm");
    transcriptionForm.set("model", "gpt-4o-mini-transcribe");
    transcriptionForm.set("response_format", "json");
    if (locale.startsWith("de")) transcriptionForm.set("language", "de");
    else if (locale.startsWith("fr")) transcriptionForm.set("language", "fr");
    else if (locale.startsWith("en")) transcriptionForm.set("language", "en");

    const transcriptionResponse = await fetch("https://api.openai.com/v1/audio/transcriptions", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}` },
      body: transcriptionForm,
    });
    if (!transcriptionResponse.ok) {
      console.error("OpenAI transcription failed:", transcriptionResponse.status);
      return jsonResponse({ error: "La transcription a échoué. Vérifie la clé et le quota API." }, 502, origin);
    }
    const transcription = await transcriptionResponse.json();
    const transcript = String(transcription.text || "").trim();
    if (!transcript) return jsonResponse({ error: "Je n’ai pas compris l’enregistrement. Réessaie plus près du micro." }, 422, origin);

    const schema = {
      type: "object",
      additionalProperties: false,
      properties: {
        title: { type: "string" },
        person: { type: "string", enum: allowedPeople },
        start_date: { type: "string" },
        start_time: { type: "string" },
        end_date: { type: "string" },
        end_time: { type: "string" },
        place: { type: "string" },
        recurrence: { type: "string", enum: ["Keine Wiederholung", "Jede Woche", "Jeden Monat"] },
      },
      required: ["title", "person", "start_date", "start_time", "end_date", "end_time", "place", "recurrence"],
    };
    const extractionPrompt = [
      "Extract one family-calendar appointment from the transcript below.",
      "The transcript may be German, French, or English. Return only the requested structured fields.",
      `Today is ${today || "unknown"} in timezone ${timezone}.`,
      `Family members: ${allowedPeople.join(", ")}.`,
      "Use ISO dates YYYY-MM-DD and 24-hour times HH:MM. Resolve relative dates using today's date and timezone.",
      "Do not invent missing details. If title/date/time/place was not said, return an empty string for that field.",
      "For person, choose the closest family member if named; otherwise use Alle.",
      "Use recurrence Keine Wiederholung unless weekly or monthly repetition was explicitly requested.",
      "If an end time was not spoken, leave it empty. Do not add the appointment to the calendar; this endpoint only fills a draft.",
      `Transcript: ${transcript}`,
    ].join("\n");

    const extractionResponse = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        input: [{ role: "user", content: [{ type: "input_text", text: extractionPrompt }] }],
        text: { format: { type: "json_schema", name: "family_appointment", strict: true, schema } },
        max_output_tokens: 300,
      }),
    });
    if (!extractionResponse.ok) {
      console.error("OpenAI field extraction failed:", extractionResponse.status);
      return jsonResponse({ error: "La préparation des champs a échoué." }, 502, origin);
    }
    const extracted = await extractionResponse.json();
    const fieldsText = parseOutputText(extracted);
    if (!fieldsText) return jsonResponse({ error: "Aucun champ n’a pu être préparé." }, 502, origin);
    const fields = JSON.parse(fieldsText);
    if (fields.start_date && !/^\d{4}-\d{2}-\d{2}$/.test(fields.start_date)) fields.start_date = "";
    if (fields.end_date && !/^\d{4}-\d{2}-\d{2}$/.test(fields.end_date)) fields.end_date = "";
    if (fields.start_time && !/^([01]\d|2[0-3]):[0-5]\d$/.test(fields.start_time)) fields.start_time = "";
    if (fields.end_time && !/^([01]\d|2[0-3]):[0-5]\d$/.test(fields.end_time)) fields.end_time = "";
    return jsonResponse({ transcript, fields }, 200, origin);
  } catch (error) {
    console.error("family-voice-event error:", error?.message || error);
    return jsonResponse({ error: "Une erreur est survenue pendant la dictée. Réessaie." }, 500, origin);
  }
});
