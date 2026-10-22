# Test de dictée vocale

La page familiale contient maintenant un bouton **Aufnahme starten** dans le formulaire de rendez-vous. Il enregistre une courte phrase, prépare les champs et attend que tu vérifies avant que tu appuies sur **Hinzufügen**. L'audio n'est pas sauvegardé par l'application; il est envoyé à OpenAI pour transcription puis le texte est converti en champs.

La page GitHub seule ne peut pas protéger une clé OpenAI. La clé doit rester dans les secrets Supabase.

## Installation dans Supabase

1. Ouvre le projet Supabase **wcjcxmhnmfkzupgpcmgq** et va dans **Edge Functions**.
2. Choisis **Deploy a new function → Via Editor** et crée une fonction appelée `family-voice-event`.
3. Ouvre [le code de la fonction](https://github.com/keversthomas-lang/Family-Application/blob/main/supabase/functions/family-voice-event/index.ts), copie tout le fichier, colle-le dans l'éditeur et déploie.
4. Dans **Project Settings → Edge Functions → Secrets** (ou **Edge Functions → Secrets**, selon la version du tableau de bord), crée `OPENAI_API_KEY` et colle la clé OpenAI. Ne mets pas cette clé dans GitHub ni dans le code de la page.
5. Dans les paramètres de la fonction, désactive **Verify JWT** pour cet endpoint. L'app n'a pas de connexion utilisateur : le code vérifie le lien secret du calendrier avec `shared_calendar_read` avant d'utiliser l'API. Les appels viennent de la page GitHub Pages; la limite de taille audio est de 5 Mo.
6. Recharge la page familiale en HTTPS et autorise l'accès au micro quand le navigateur le demande.

Le fichier [config.toml](https://github.com/keversthomas-lang/Family-Application/blob/main/supabase/config.toml) contient aussi le réglage `verify_jwt = false` si tu déploies plus tard depuis la CLI.

## Essai

Dans **Termin hinzufügen**, appuie sur **Aufnahme starten**, autorise le micro et dis par exemple : « Noé, dentiste le 3 novembre à 15 heures, au cabinet médical. » Appuie sur **Aufnahme beenden**. Vérifie les champs remplis puis appuie sur **Hinzufügen** pour enregistrer. La dictée ne sauvegarde jamais le rendez-vous elle-même.

La fonction utilise `gpt-4o-mini-transcribe` pour l'audio et un modèle texte pour préparer les champs. Le prix publié pour la transcription mini est de 0,003 $ par minute audio, auquel s'ajoute un petit coût de traitement du texte; vérifie le tarif actuel avant des essais nombreux : [tarifs OpenAI](https://platform.openai.com/pricing/).

Si la fonction répond 404, elle n'est pas déployée. Une erreur signalant `OPENAI_API_KEY` signifie que le secret n'a pas été ajouté. Une erreur de quota ou d'authentification vient de la clé ou de la facturation OpenAI.
