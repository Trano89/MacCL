import Foundation

/// UI languages offered in Preferences.
enum AppLanguage: String, CaseIterable, Identifiable {
    case en, fr, de, pt, es

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .en: return "English"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .pt: return "Português"
        case .es: return "Español"
        }
    }

    /// Best match for the system language, used on first launch.
    static var systemDefault: AppLanguage {
        let preferred = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en"
        return AppLanguage(rawValue: String(preferred)) ?? .en
    }
}

/// Tiny string table. `L10n.t("key")` returns the string in the app language.
@MainActor
enum L10n {
    static func t(_ key: String) -> String {
        guard let entry = table[key] else { return key }
        switch AppSettings.shared.language {
        case .fr: return entry.fr
        case .en: return entry.en
        case .de: return entry.de
        case .pt: return entry.pt
        case .es: return entry.es
        }
    }

    /// t() with a single %@ placeholder.
    static func t(_ key: String, _ arg: String) -> String {
        t(key).replacingOccurrences(of: "%@", with: arg)
    }

    // swiftlint:disable line_length
    private static let table: [String: (fr: String, en: String, de: String, pt: String, es: String)] = [
        // Sidebar
        "new_conversation": ("Nouvelle conversation", "New conversation", "Neue Unterhaltung", "Nova conversa", "Nueva conversación"),
        "history": ("Historique", "History", "Verlauf", "Histórico", "Historial"),
        "no_conversation": ("Aucune conversation", "No conversations", "Keine Unterhaltungen", "Nenhuma conversa", "Sin conversaciones"),
        "delete": ("Supprimer", "Delete", "Löschen", "Apagar", "Eliminar"),
        "preferences": ("Préférences", "Preferences", "Einstellungen", "Preferências", "Preferencias"),

        // Composer
        "write_placeholder": ("Écrivez à Claude…", "Message Claude…", "Nachricht an Claude…", "Escreva para o Claude…", "Escribe a Claude…"),
        "send_help": ("Envoyer (Maj+Entrée)", "Send (Shift+Return)", "Senden (Umschalt+Eingabe)", "Enviar (Shift+Retorno)", "Enviar (Mayús+Retorno)"),
        "interrupt_help": ("Interrompre", "Stop", "Anhalten", "Interromper", "Detener"),
        "attach_help": ("Joindre des fichiers", "Attach files", "Dateien anhängen", "Anexar ficheiros", "Adjuntar archivos"),
        "commands_help": ("Commandes Claude Code", "Claude Code commands", "Claude-Code-Befehle", "Comandos do Claude Code", "Comandos de Claude Code"),
        "instructions": ("Instructions", "Instructions", "Anweisungen", "Instruções", "Instrucciones"),
        "empty_state": ("Écrivez un message pour commencer", "Write a message to get started", "Schreiben Sie eine Nachricht, um zu beginnen", "Escreva uma mensagem para começar", "Escribe un mensaje para comenzar"),
        "model_help": ("Choisir le modèle (LLM)", "Choose the model (LLM)", "Modell (LLM) wählen", "Escolher o modelo (LLM)", "Elegir el modelo (LLM)"),
        "perm_help": ("Permissions — cliquer pour changer.", "Permissions — click to change.", "Berechtigungen — zum Ändern klicken.", "Permissões — clique para mudar.", "Permisos — clic para cambiar."),
        "effort_help": ("Effort de raisonnement — cliquer pour changer.", "Reasoning effort — click to change.", "Denkaufwand — zum Ändern klicken.", "Esforço de raciocínio — clique para mudar.", "Esfuerzo de razonamiento — clic para cambiar."),
        "folder_help": ("Dossier de travail", "Working directory", "Arbeitsordner", "Pasta de trabalho", "Carpeta de trabajo"),
        "instructions_help": ("Instructions .md injectées dans le prompt", ".md instructions injected into the prompt", "In den Prompt eingefügte .md-Anweisungen", "Instruções .md injetadas no prompt", "Instrucciones .md inyectadas en el prompt"),
        "reasoning": ("Réflexion", "Reasoning", "Denkprozess", "Raciocínio", "Razonamiento"),

        // Transcript bits
        "done": ("Terminé", "Done", "Fertig", "Concluído", "Completado"),
        "error": ("Erreur", "Error", "Fehler", "Erro", "Error"),
        "input": ("Entrée", "Input", "Eingabe", "Entrada", "Entrada"),
        "result": ("Résultat", "Result", "Ergebnis", "Resultado", "Resultado"),
        "image": ("Image", "Image", "Bild", "Imagem", "Imagen"),
        "text": ("Texte", "Text", "Text", "Texto", "Texto"),
        "remove_attachment": ("Retirer", "Remove", "Entfernen", "Remover", "Quitar"),
        "thinking_enabled": ("Réflexion active", "Thinking enabled", "Denken aktiviert", "Raciocínio ativo", "Razonamiento activo"),
        "thinking_disabled": ("Réflexion inactive", "Thinking disabled", "Denken inaktiv", "Raciocínio inativo", "Razonamiento inactivo"),

        // Settings
        "tab_general": ("Général", "General", "Allgemein", "Geral", "General"),
        "tab_appearance": ("Apparence", "Appearance", "Erscheinungsbild", "Aparência", "Apariencia"),
        "tab_thanks": ("Remerciements", "Credits", "Danksagung", "Agradecimentos", "Agradecimientos"),
        "language": ("Langue", "Language", "Sprache", "Idioma", "Idioma"),
        "detected_binary": ("Binaire détecté", "Detected binary", "Erkannte Binärdatei", "Binário detetado", "Binario detectado"),
        "not_found": ("introuvable", "not found", "nicht gefunden", "não encontrado", "no encontrado"),
        "custom_path": ("Chemin personnalisé (optionnel)", "Custom path (optional)", "Benutzerdefinierter Pfad (optional)", "Caminho personalizado (opcional)", "Ruta personalizada (opcional)"),
        "default_permission": ("Mode de permission par défaut", "Default permission mode", "Standard-Berechtigungsmodus", "Modo de permissão padrão", "Modo de permiso predeterminado"),
        "ollama_server": ("Serveur Ollama", "Ollama server", "Ollama-Server", "Servidor Ollama", "Servidor Ollama"),
        "server_url": ("URL du serveur", "Server URL", "Server-URL", "URL do servidor", "URL del servidor"),
        "scan": ("Scanner", "Scan", "Scannen", "Procurar", "Escanear"),
        "scan_hint": ("« Scanner » cherche les serveurs Ollama (port 11434) en local et sur tous vos réseaux.", "“Scan” looks for Ollama servers (port 11434) locally and on all your networks.", "„Scannen“ sucht Ollama-Server (Port 11434) lokal und in allen Netzwerken.", "“Procurar” procura servidores Ollama (porta 11434) localmente e em todas as redes.", "“Escanear” busca servidores Ollama (puerto 11434) en local y en todas tus redes."),
        "no_server_hint": ("Aucun serveur trouvé. Sur une machine distante, lancez : OLLAMA_HOST=0.0.0.0 ollama serve", "No server found. On a remote machine, run: OLLAMA_HOST=0.0.0.0 ollama serve", "Kein Server gefunden. Auf einem entfernten Rechner: OLLAMA_HOST=0.0.0.0 ollama serve", "Nenhum servidor encontrado. Numa máquina remota: OLLAMA_HOST=0.0.0.0 ollama serve", "No se encontró servidor. En una máquina remota: OLLAMA_HOST=0.0.0.0 ollama serve"),
        "models_count": ("modèle(s)", "model(s)", "Modell(e)", "modelo(s)", "modelo(s)"),
        "context_tokens": ("Contexte & tokens", "Context & tokens", "Kontext & Tokens", "Contexto e tokens", "Contexto y tokens"),
        "context_window": ("Fenêtre de contexte (num_ctx)", "Context window (num_ctx)", "Kontextfenster (num_ctx)", "Janela de contexto (num_ctx)", "Ventana de contexto (num_ctx)"),
        "recommended": ("recommandé", "recommended", "empfohlen", "recomendado", "recomendado"),
        "model_max": ("max modèle", "model max", "Modellmaximum", "máx. do modelo", "máx. del modelo"),
        "custom_value": ("Valeur personnalisée", "Custom value", "Eigener Wert", "Valor personalizado", "Valor personalizado"),
        "ctx_hint": ("Fenêtre de contexte des modèles locaux (le « max tokens » d'Ollama). Plus c'est grand, plus le modèle réserve de RAM.", "Context window for local models (Ollama's “max tokens”). The bigger it is, the more RAM the model reserves.", "Kontextfenster lokaler Modelle (Olamas „max tokens“). Je größer, desto mehr RAM reserviert das Modell.", "Janela de contexto dos modelos locais (o “max tokens” do Ollama). Quanto maior, mais RAM o modelo reserva.", "Ventana de contexto de los modelos locales (el “max tokens” de Ollama). Cuanto más grande, más RAM reserva el modelo."),
        "max_reply": ("Réponse max (num_predict)", "Max reply (num_predict)", "Max. Antwort (num_predict)", "Resposta máx. (num_predict)", "Respuesta máx. (num_predict)"),
        "auto_follow": ("Auto — suit Claude Code", "Auto — follows Claude Code", "Auto — folgt Claude Code", "Auto — segue o Claude Code", "Auto — sigue a Claude Code"),
        "unlimited": ("Illimité — jusqu'au contexte", "Unlimited — up to the context", "Unbegrenzt — bis zum Kontext", "Ilimitado — até ao contexto", "Ilimitado — hasta el contexto"),
        "predict_hint": ("Tokens générés au maximum par réponse (borné par le contexte).", "Maximum tokens generated per reply (bounded by the context).", "Maximal erzeugte Tokens pro Antwort (durch den Kontext begrenzt).", "Máximo de tokens gerados por resposta (limitado pelo contexto).", "Tokens máximos generados por respuesta (limitado por el contexto)."),
        "local_router": ("Routeur local", "Local router", "Lokaler Router", "Router local", "Enrutador local"),
        "show_reasoning": ("Afficher les réflexions du modèle", "Show the model's reasoning", "Denkprozess des Modells anzeigen", "Mostrar o raciocínio do modelo", "Mostrar el razonamiento del modelo"),
        "reasoning_hint": ("Active le raisonnement des modèles locaux (plus lent) et l'affiche sous la conversation.", "Enables local models' reasoning (slower) and shows it under the conversation.", "Aktiviert das Denken lokaler Modelle (langsamer) und zeigt es unter der Unterhaltung an.", "Ativa o raciocínio dos modelos locais (mais lento) e mostra-o sob a conversa.", "Activa el razonamiento de los modelos locales (más lento) y lo muestra bajo la conversación."),
        "router_port": ("Port du routeur local", "Local router port", "Port des lokalen Routers", "Porta do router local", "Puerto del enrutador local"),
        "node_detected": ("Node détecté", "Node detected", "Node erkannt", "Node detetado", "Node detectado"),
        "about": ("À propos", "About", "Über", "Sobre", "Acerca de"),
        "about_text": ("Interface native pour Claude Code. Tous les outils du CLI sont pilotés via le protocole stream-json.", "Native interface for Claude Code. All CLI tools are driven through the stream-json protocol.", "Native Oberfläche für Claude Code. Alle CLI-Tools werden über das stream-json-Protokoll gesteuert.", "Interface nativa para o Claude Code. Todas as ferramentas do CLI são controladas pelo protocolo stream-json.", "Interfaz nativa para Claude Code. Todas las herramientas del CLI se controlan mediante el protocolo stream-json."),
        "version": ("Version", "Version", "Version", "Versão", "Versión"),

        // Appearance
        "theme_mode": ("Mode d'affichage", "Display mode", "Anzeigemodus", "Modo de exibição", "Modo de visualización"),
        "system": ("Système", "System", "System", "Sistema", "Sistema"),
        "light": ("Clair", "Light", "Hell", "Claro", "Claro"),
        "dark": ("Sombre", "Dark", "Dunkel", "Escuro", "Oscuro"),
        "accent_color": ("Couleur d'accentuation", "Accent color", "Akzentfarbe", "Cor de destaque", "Color de acento"),

        // Thanks tab
        "thanks_by": ("MacCL est développé par Antonin Trottet.", "MacCL is developed by Antonin Trottet.", "MacCL wird von Antonin Trottet entwickelt.", "O MacCL é desenvolvido por Antonin Trottet.", "MacCL está desarrollado por Antonin Trottet."),
        "thanks_support": ("Si cette application vous est utile, vous pouvez soutenir son développement :", "If this app is useful to you, you can support its development:", "Wenn Ihnen diese App hilft, können Sie die Entwicklung unterstützen:", "Se esta aplicação lhe for útil, pode apoiar o seu desenvolvimento:", "Si esta aplicación te resulta útil, puedes apoyar su desarrollo:"),
        "donate": ("Faire un don PayPal", "Donate via PayPal", "Per PayPal spenden", "Doar via PayPal", "Donar por PayPal"),
        "thanks_note": ("Merci ! ❤️", "Thank you! ❤️", "Danke! ❤️", "Obrigado! ❤️", "¡Gracias! ❤️"),

        // Sheets
        "launch_params": ("Paramètres de lancement", "Launch parameters", "Startparameter", "Parâmetros de arranque", "Parámetros de inicio"),
        "equivalent_cmd": ("Commande terminal équivalente", "Equivalent terminal command", "Entsprechender Terminal-Befehl", "Comando de terminal equivalente", "Comando de terminal equivalente"),
        "choose": ("Choisir…", "Choose…", "Auswählen…", "Escolher…", "Elegir…"),
        "cancel": ("Annuler", "Cancel", "Abbrechen", "Cancelar", "Cancelar"),
        "start": ("Démarrer", "Start", "Starten", "Iniciar", "Iniciar"),
        "close": ("Fermer", "Close", "Schließen", "Fechar", "Cerrar"),
        "refresh": ("Rafraîchir", "Refresh", "Aktualisieren", "Atualizar", "Actualizar"),
        "model_llm": ("Modèle (LLM)", "Model (LLM)", "Modell (LLM)", "Modelo (LLM)", "Modelo (LLM)"),
        "permissions": ("Permissions", "Permissions", "Berechtigungen", "Permissões", "Permisos"),
        "effort": ("Effort de raisonnement", "Reasoning effort", "Denkaufwand", "Esforço de raciocínio", "Esfuerzo de razonamiento"),
        "save": ("Enregistrer", "Save", "Sichern", "Guardar", "Guardar"),
        "new": ("Nouveau", "New", "Neu", "Novo", "Nuevo"),
        "folder": ("Dossier", "Folder", "Ordner", "Pasta", "Carpeta"),
        "actives": ("active(s)", "active", "aktiv", "ativas", "activas"),
        "new_instruction": ("Nouvelle instruction", "New instruction", "Neue Anweisung", "Nova instrução", "Nueva instrucción"),
        "instr_msg": ("Un fichier .md sera créé dans la bibliothèque et activé.", "A .md file will be created in the library and enabled.", "Eine .md-Datei wird in der Bibliothek erstellt und aktiviert.", "Um ficheiro .md será criado na biblioteca e ativado.", "Se creará un archivo .md en la biblioteca y se activará."),
        "select_instruction": ("Sélectionnez une instruction, ou créez-en une.", "Select an instruction, or create one.", "Wählen Sie eine Anweisung oder erstellen Sie eine.", "Selecione uma instrução ou crie uma.", "Selecciona una instrucción o crea una."),
        "file_name": ("nom du fichier", "file name", "Dateiname", "nome do ficheiro", "nombre del archivo"),

        // Permission modes
        "perm_bypass": ("Tous les outils (bypass)", "All tools (bypass)", "Alle Tools (Bypass)", "Todas as ferramentas (bypass)", "Todas las herramientas (bypass)"),
        "perm_accept": ("Éditions auto", "Auto-accept edits", "Automatische Bearbeitungen", "Edições automáticas", "Ediciones automáticas"),
        "perm_plan": ("Mode plan", "Plan mode", "Planmodus", "Modo plano", "Modo plan"),
        "perm_default": ("Demander (défaut)", "Ask (default)", "Nachfragen (Standard)", "Perguntar (padrão)", "Preguntar (predeterminado)"),
        "perm_bypass_x": ("Tous les outils s'exécutent sans confirmation.", "All tools run without confirmation.", "Alle Tools laufen ohne Bestätigung.", "Todas as ferramentas correm sem confirmação.", "Todas las herramientas se ejecutan sin confirmación."),
        "perm_accept_x": ("Les modifications de fichiers sont acceptées automatiquement.", "File edits are accepted automatically.", "Dateiänderungen werden automatisch akzeptiert.", "As edições de ficheiros são aceites automaticamente.", "Las ediciones de archivos se aceptan automáticamente."),
        "perm_plan_x": ("L'agent planifie sans rien exécuter.", "The agent plans without executing anything.", "Der Agent plant, ohne etwas auszuführen.", "O agente planeia sem executar nada.", "El agente planifica sin ejecutar nada."),
        "perm_default_x": ("Les outils non autorisés sont refusés.", "Unauthorized tools are refused.", "Nicht erlaubte Tools werden abgelehnt.", "Ferramentas não autorizadas são recusadas.", "Las herramientas no autorizadas se rechazan."),

        // Effort levels
        "effort_low": ("Faible", "Low", "Niedrig", "Baixo", "Bajo"),
        "effort_medium": ("Moyen", "Medium", "Mittel", "Médio", "Medio"),
        "effort_high": ("Élevé", "High", "Hoch", "Alto", "Alto"),
        "effort_xhigh": ("Très élevé", "Very high", "Sehr hoch", "Muito alto", "Muy alto"),
        "effort_max": ("Maximum", "Maximum", "Maximal", "Máximo", "Máximo"),
        "effort_low_x": ("Réponses rapides, raisonnement minimal.", "Fast replies, minimal reasoning.", "Schnelle Antworten, minimales Denken.", "Respostas rápidas, raciocínio mínimo.", "Respuestas rápidas, razonamiento mínimo."),
        "effort_medium_x": ("Équilibre entre vitesse et réflexion.", "Balance between speed and reasoning.", "Balance zwischen Tempo und Denken.", "Equilíbrio entre velocidade e raciocínio.", "Equilibrio entre velocidad y razonamiento."),
        "effort_high_x": ("Plus de réflexion, meilleure qualité (recommandé).", "More reasoning, better quality (recommended).", "Mehr Denken, bessere Qualität (empfohlen).", "Mais raciocínio, melhor qualidade (recomendado).", "Más razonamiento, mejor calidad (recomendado)."),
        "effort_xhigh_x": ("Raisonnement approfondi — plus lent.", "Deep reasoning — slower.", "Tiefes Denken — langsamer.", "Raciocínio profundo — mais lento.", "Razonamiento profundo — más lento."),
        "effort_max_x": ("Effort maximal — le plus lent.", "Maximum effort — the slowest.", "Maximaler Aufwand — am langsamsten.", "Esforço máximo — o mais lento.", "Esfuerzo máximo — el más lento."),

        // Status / notices
        "ready": ("Prêt", "Ready", "Bereit", "Pronto", "Listo"),
        "interrupted": ("Interrompu", "Interrupted", "Unterbrochen", "Interrompido", "Interrumpido"),
        "conversation_loaded": ("Conversation chargée", "Conversation loaded", "Unterhaltung geladen", "Conversa carregada", "Conversación cargada"),
        "sending_to": ("Envoi à %@…", "Sending to %@…", "Senden an %@…", "A enviar para %@…", "Enviando a %@…"),
        "done_ok": ("Prêt", "Ready", "Bereit", "Pronto", "Listo"),
        "done_error": ("Terminé avec erreur", "Finished with error", "Mit Fehler beendet", "Concluído com erro", "Terminado con error"),
        "compacting": ("Contexte plein — compactage…", "Context full — compacting…", "Kontext voll — Komprimierung…", "Contexto cheio — compactação…", "Contexto lleno — compactando…"),
        "compact_notice": ("Limite de contexte atteinte — compactage automatique (/compact), puis renvoi du message.", "Context limit reached — auto-compacting (/compact), then re-sending the message.", "Kontextlimit erreicht — automatische Komprimierung (/compact), dann erneutes Senden.", "Limite de contexto atingido — compactação automática (/compact) e reenvio da mensagem.", "Límite de contexto alcanzado — compactación automática (/compact) y reenvío del mensaje."),
        "compacted_resend": ("Contexte compacté ✓ — renvoi du dernier message…", "Context compacted ✓ — re-sending the last message…", "Kontext komprimiert ✓ — letzte Nachricht wird erneut gesendet…", "Contexto compactado ✓ — a reenviar a última mensagem…", "Contexto compactado ✓ — reenviando el último mensaje…"),
        "compact_failed": ("Le compactage a échoué — réessayez ou démarrez une nouvelle conversation.", "Compaction failed — retry or start a new conversation.", "Komprimierung fehlgeschlagen — erneut versuchen oder neue Unterhaltung starten.", "A compactação falhou — tente novamente ou inicie uma nova conversa.", "La compactación falló — reintenta o inicia una nueva conversación."),
        "ollama_fallback": ("Serveur Ollama injoignable — bascule sur localhost", "Ollama server unreachable — switching to localhost", "Ollama-Server nicht erreichbar — Wechsel zu localhost", "Servidor Ollama inacessível — a mudar para localhost", "Servidor Ollama inaccesible — cambiando a localhost"),
        "waiting_local": ("%@ réfléchit… les modèles locaux peuvent être lents au premier tour.", "%@ is thinking… local models can be slow on the first turn.", "%@ denkt nach… lokale Modelle können beim ersten Durchlauf langsam sein.", "%@ está a pensar… modelos locais podem ser lentos na primeira volta.", "%@ está pensando… los modelos locales pueden ser lentos en el primer turno."),
        "waiting_remote": ("En attente de %@...", "Waiting for %@...", "Warten auf %@...", "A espera de %@...", "Esperando a %@..."),
        "still_running": ("Toujours en cours (gros modèle ou long prompt) - patientez ou cliquez sur stop.", "Still running (big model or long prompt) - wait or press stop.", "Läuft noch (großes Modell oder langer Prompt) - warten oder Stop drücken.", "Ainda em curso (modelo grande ou prompt longo) - aguarde ou toque em stop.", "Aún en curso (modelo grande o prompt largo) - espera o pulsa stop."),
        "binary_not_found": ("Binaire `claude` introuvable. Renseignez son chemin dans les Réglages (Cmd,).", "Binary `claude` not found. Set its path in Settings (Cmd,).", "Binärdatei 'claude' nicht gefunden. Pfad in den Einstellungen angeben (Cmd,).", "Binário 'claude' não encontrado. Informe o caminho nos Ajustes (Cmd,).", "Binario `claude` no encontrado. Configure su ruta en Preferencias (Cmd,)."),
        "router_error": ("Erreur routeur local", "Local router error", "Lokaler Router-Fehler", "Erro do router local", "Error del router local"),
        "launch_failed": ("Lancement échoué : %@", "Launch failed: %@", "Start fehlgeschlagen: %@", "Arranque falhou: %@", "Inicio falló: %@"),
        "session_terminated": ("La session `claude` s'est arrêtée (code %@).", "The `claude` session terminated (code %@).", "Die 'claude' Sitzung wurde beendet (Code %@).", "A sessão 'claude' foi encerrada (código %@).", "La sesión de `claude` terminó (código %@)."),
        "session_stopped": ("Session arrêtée", "Session stopped", "Sitzung gestoppt", "Sessão interrompida", "Sesión detenida"),
        "permission_pending": ("Requête de permission reçue (dialogue natif à venir).", "Permission request received (native dialog coming soon).", "Berechtigungsanfrage erhalten (nativer Dialog kommt bald).", "Pedido de permissão recebido (diálogo nativo em breve).", "Solicitud de permiso recibida (diálogo nativo próximamente)."),
        "invalid_ollama_url": ("L'URL du serveur Ollama n'est pas valide. Utilisez http:// ou https://.", "Ollama server URL is invalid. Use http:// or https://.", "Die Ollama-Server-URL ist ungültig. Verwenden Sie http:// oder https://.", "O URL do servidor Ollama é inválido. Use http:// ou https://.", "La URL del servidor Ollama es inválida. Usa http:// o https://."),
        "invalid_port": ("Le port doit être entre 1024 et 65535.", "Port must be between 1024 and 65535.", "Der Port muss zwischen 1024 und 65535 liegen.", "A porta deve estar entre 1024 e 65535.", "El puerto debe estar entre 1024 y 65535."),
        "redacted": ("[REDACTED]", "[REDACTED]", "[VERHEIMLICHT]", "[OCULTO]", "[OCULTADO]"),

        // Agent monitor
        "agent_monitor_title": ("Agents", "Agents", "Agenten", "Agentes", "Agentes"),
        "agent_monitor_empty": ("Aucun sous-agent actif.\nLes sous-agents Claude Code apparaîtront ici.", "No active sub-agents.\nClaude Code sub-agents will appear here.", "Keine aktiven Agenten.\nClaude Code-Agenten erscheinen hier.", "Nenhum agente ativo.\nOs agentes do Claude Code aparecerão aqui.", "No hay agentes activos.Los agentes de Claude Code aparecerán aquí."),
        "agent_monitor_footer_idle": ("Inactif", "Idle", "Inaktiv", "Inativo", "Inactivo"),
        "agent_monitor_footer_separator": (": en cours, ", ": running, ", ": läuft, ", ": em curso, ", ": en curso, "),
        "agent_queued": ("En attente", "Waiting", "Wartet", "Aguardando", "Esperando"),
        "agent_running": ("En cours", "Running", "Läuft", "Em curso", "Corriendo"),
        "agent_completed": ("Terminé", "Done", "Fertig", "Concluído", "Completado"),
        "agent_failed": ("Échoué", "Failed", "Fehlgeschlagen", "Falhou", "Falló"),
        "agent_link": ("traitement agents", "agent processing", "Agentverarbeitung", "processamento de agentes", "procesamiento de agentes"),

        // Workspace panel
        "workspace_panel_title": ("Espace de travail", "Workspace", "Arbeitsbereich", "Área de trabalho", "Área de trabajo"),
        "workspace_panel_empty": ("L'activité de l'espace de travail apparaîtra ici.", "Workspace activity will appear here.", "Arbeitsbereichsaktivität erscheint hier.", "A atividade da área de trabalho aparecerá aqui.", "La actividad del área de trabajo aparecerá aquí."),
        "workspace_footer_idle": ("Aucune activité", "No activity", "Keine Aktivität", "Sem atividade", "Sin actividad"),

        // Standby servers
        "standby_servers": ("Serveurs standby", "Standby servers", "Standby-Server", "Servidores standby", "Servidores de espera"),
        "add_server": ("Ajouter un serveur…", "Add server…", "Server hinzufügen…", "Adicionar servidor…", "Agregar servidor…"),
        "remove_server": ("Supprimer", "Delete", "Löschen", "Apagar", "Eliminar"),
        "standby_hint": ("Serveurs Ollama sauvegardés pour une utilisation rapide. Les serveurs distants sont signalés par un avertissement.", "Saved Ollama servers for quick access. Remote servers are flagged with a warning.", "Für den Schnellzugriff gespeicherte Ollama-Server. Entfernte Server werden mit einer Warnung markiert.", "Servidores Ollama salvos para acesso rápido. Servidores remotos são sinalizados com um aviso.", "Servidores Ollama guardados para acceso rápido. Los servidores remotos se marcan con una advertencia."),
        "standby_active": ("Actif", "Active", "Aktiv", "Ativo", "Activo"),

        // Network server warning
        "remote_server_warning": ("⚠️ Serveur Ollama distant — les requêtes transitent par votre réseau local.", "⚠️ Remote Ollama server — requests travel over your network.", "⚠️ Entfernter Ollama-Server — Anfragen werden über Ihr Netzwerk gesendet.", "⚠️ Servidor Ollama remoto — as solicitações viajam pela sua rede.", "⚠️ Servidor Ollama remoto — las solicitudes viajan por su red."),

        // Network section
        "network_servers": ("Serveurs réseau", "Network servers", "Netzwerkserver", "Servidores de rede", "Servidores de red"),

        // Standby server manual entry
        "manual_entry": ("Saisie manuelle", "Manual entry", "Manuelle Eingabe", "Entrada manual", "Entrada manual"),
        "add": ("Ajouter", "Add", "Hinzufügen", "Adicionar", "Agregar"),

        // Standby server picker sheet
        "select_server": ("Sélectionner un serveur…", "Select a server…", "Server auswählen…", "Selecionar servidor…", "Seleccionar servidor…"),
        "enter_url": ("Entrer une URL…", "Enter a URL…", "URL eingeben…", "Introduzir URL…", "Introducir una URL…"),

        // Server health indicators
        "health_checking": ("Vérification…", "Checking…", "Überprüfung…", "Verificando…", "Verificando…"),
        "health_reachable": ("En ligne", "Online", "Online", "Online", "En línea"),
        "health_unreachable": ("Hors ligne", "Offline", "Offline", "Offline", "Desconectado"),

        // URL validation feedback
        "url_valid": ("URL valide ✓", "Valid URL ✓", "Gültige URL ✓", "URL válida ✓", "URL válida ✓"),
        "url_invalid_scheme": ("Schéma invalide — utilisez http:// ou https://", "Invalid scheme — use http:// or https://", "Ungültiges Schema — verwenden Sie http:// oder https://", "Esquema inválido — use http:// ou https://", "Esquema inválido — use http:// o https://"),
        "url_invalid_host": ("Hôte invalide — l'URL doit contenir un nom de serveur", "Invalid host — URL must contain a server name", "Ungültiger Host — die URL muss einen Servernamen enthalten", "Host inválido — a URL deve conter um nome de servidor", "Host inválido — la URL debe contener un nombre de servidor"),
        "url_empty": ("Entrez une URL valide pour vérifier le serveur", "Enter a valid URL to check the server", "Geben Sie eine gültige URL ein, um den Server zu prüfen", "Insira uma URL válida para verificar o servidor", "Ingrese una URL válida para verificar el servidor"),

        // Context / predict range errors
        "ctx_min": ("Valeur minimale : 1024", "Minimum value: 1024", "Mindestwert: 1024", "Valor mínimo: 1024", "Valor mínimo: 1024"),
        "ctx_max": ("Valeur maximale : 131072 (256k)", "Maximum value: 131072 (256k)", "Maximalwert: 131072 (256k)", "Valor máximo: 131072 (256k)", "Valor máximo: 131072 (256k)"),
        "predict_min": ("Valeur minimale : 128", "Minimum value: 128", "Mindestwert: 128", "Valor mínimo: 128", "Valor mínimo: 128"),
        "predict_max": ("Valeur maximale : 65536", "Maximum value: 65536", "Maximalwert: 65536", "Valor máximo: 65536", "Valor máximo: 65536"),

        // Server add/remove confirmation
        "confirm_add_server_title": ("Ajouter le serveur ?", "Add server?", "Server hinzufügen?", "Adicionar servidor?", "¿Agregar servidor?"),
        "confirm_add_server_message": ("Le serveur sera vérifié et ajouté à la liste standby.", "The server will be checked and added to the standby list.", "Der Server wird geprüft und der Standby-Liste hinzugefügt.", "O servidor será verificado e adicionado à lista standby.", "El servidor será verificado y agregado a la lista standby."),
        "confirm_remove_server_title": ("Supprimer le serveur ?", "Remove server?", "Server entfernen?", "Remover servidor?", "¿Eliminar servidor?"),
        "confirm_remove_server_message": ("Êtes-vous sûr de vouloir supprimer « %@ » ? Cette action est irréversible.", "Are you sure you want to remove « %@ »? This action cannot be undone.", "Sind Sie sicher, dass Sie « %@ » entfernen möchten? Diese Aktion kann nicht rückgängig gemacht werden.", "Tem certeza que deseja remover « %@ »? Esta ação não pode ser desfeita.", "¿Está seguro de que desea eliminar « %@ »? Esta acción no se puede deshacer."),
        "confirm_yes": ("Supprimer", "Remove", "Entfernen", "Remover", "Eliminar"),
        "confirm_no": ("Annuler", "Cancel", "Abbrechen", "Cancelar", "Cancelar"),

        // Server section headers (refactored)
        "add_server_url": ("URL du serveur", "Server URL", "Server-URL", "URL do servidor", "URL del servidor"),
        "add_server_placeholder": ("localhost:11434 ou http://ip:port", "localhost:11434 or http://ip:port", "localhost:11434 oder http://ip:port", "localhost:11434 ou http://ip:porta", "localhost:11434 o http://ip:puerto"),

        // Background/foreground auto-heal
        "router_restarting": ("Routeur local en cours de redémarrage…", "Restarting local router…", "Lokaler Router wird neu gestartet…", "Reiniciando router local…", "Reiniciando enrutador local…"),
        "router_recovered": ("Routeur local récupéré ✓ — prêt à nouveau.", "Local router recovered ✓ — ready again.", "Lokaler Router wiederhergestellt ✓ — bereit.", "Router local recuperado ✓ — pronto novamente.", "Enrutador local recuperado ✓ — listo de nuevo."),
        "router_recovery_failed": ("Récupération du routeur échouée — vérifiez Ollama.", "Router recovery failed — check Ollama.", "Router-Wiederherstellung fehlgeschlagen — prüfen Sie Ollama.", "Recuperação do router falhou — verifique o Ollama.", "Recuperación del enrutador fallida — verifica Ollama."),
        "heal_failed": ("Réparation automatique échouée.", "Auto-repair failed.", "Automatische Reparatur fehlgeschlagen.", "Reparação automática falhou.", "Reparación automática falló."),

        // Standby server picker
        "server_none_found": ("Aucun serveur trouvé", "No server found", "Kein Server gefunden", "Nenhum servidor encontrado", "Ningún servidor encontrado"),
    ]
    // swiftlint:enable line_length
}
