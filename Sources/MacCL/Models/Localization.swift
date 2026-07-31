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
        "commands_help": ("Commandes Claude Code", "Claude Code commands", "Claude-Code-Befehle", "Comandos do Claude Code", "Comandos de Claude Code"),
        "instructions": ("Instructions", "Instructions", "Anweisungen", "Instruções", "Instrucciones"),
        "folder_help": ("Dossier de travail", "Working directory", "Arbeitsordner", "Pasta de trabalho", "Carpeta de trabajo"),
        "reasoning": ("Réflexion", "Reasoning", "Denkprozess", "Raciocínio", "Razonamiento"),

        // Transcript bits
        "done": ("Terminé", "Done", "Fertig", "Concluído", "Completado"),
        "error": ("Erreur", "Error", "Fehler", "Erro", "Error"),
        "input": ("Entrée", "Input", "Eingabe", "Entrada", "Entrada"),
        "result": ("Résultat", "Result", "Ergebnis", "Resultado", "Resultado"),
        "image": ("Image", "Image", "Bild", "Imagem", "Imagen"),
        "text": ("Texte", "Text", "Text", "Texto", "Texto"),

        // Settings
        "tab_thanks": ("Remerciements", "Credits", "Danksagung", "Agradecimentos", "Agradecimientos"),
        "detected_binary": ("Binaire détecté", "Detected binary", "Erkannte Binärdatei", "Binário detetado", "Binario detectado"),
        "not_found": ("introuvable", "not found", "nicht gefunden", "não encontrado", "no encontrado"),
        "custom_path": ("Chemin personnalisé (optionnel)", "Custom path (optional)", "Benutzerdefinierter Pfad (optional)", "Caminho personalizado (opcional)", "Ruta personalizada (opcional)"),
        "default_permission": ("Mode de permission par défaut", "Default permission mode", "Standard-Berechtigungsmodus", "Modo de permissão padrão", "Modo de permiso predeterminado"),
        "scan": ("Scanner", "Scan", "Scannen", "Procurar", "Escanear"),
        "models_count": ("modèle(s)", "model(s)", "Modell(e)", "modelo(s)", "modelo(s)"),
        "show_reasoning": ("Afficher les réflexions du modèle", "Show the model's reasoning", "Denkprozess des Modells anzeigen", "Mostrar o raciocínio do modelo", "Mostrar el razonamiento del modelo"),
        "reasoning_hint": ("Affiche le raisonnement du modèle sous la conversation. Sa profondeur suit le niveau d'effort choisi, pour les modèles Anthropic comme pour Ollama.", "Shows the model's reasoning under the conversation. Its depth follows the chosen effort level, for Anthropic and Ollama models alike.", "Zeigt das Denken des Modells unter der Unterhaltung. Seine Tiefe folgt der gewählten Effort-Stufe — für Anthropic- wie für Ollama-Modelle.", "Mostra o raciocínio do modelo sob a conversa. A profundidade segue o nível de esforço escolhido, tanto para modelos Anthropic como Ollama.", "Muestra el razonamiento del modelo bajo la conversación. Su profundidad sigue el nivel de esfuerzo elegido, tanto para modelos Anthropic como Ollama."),
        "about": ("À propos", "About", "Über", "Sobre", "Acerca de"),
        "about_text": ("Interface native pour Claude Code. Tous les outils du CLI sont pilotés via le protocole stream-json.", "Native interface for Claude Code. All CLI tools are driven through the stream-json protocol.", "Native Oberfläche für Claude Code. Alle CLI-Tools werden über das stream-json-Protokoll gesteuert.", "Interface nativa para o Claude Code. Todas as ferramentas do CLI são controladas pelo protocolo stream-json.", "Interfaz nativa para Claude Code. Todas las herramientas del CLI se controlan mediante el protocolo stream-json."),
        "version": ("Version", "Version", "Version", "Versão", "Versión"),

        // Appearance
        // Composer + transcript chrome
        "empty_state": ("Écrivez un message pour commencer", "Write a message to get started", "Schreiben Sie eine Nachricht, um zu beginnen", "Escreva uma mensagem para começar", "Escribe un mensaje para comenzar"),
        "write_placeholder": ("Écrivez à Claude…", "Message Claude…", "Nachricht an Claude…", "Escreva para o Claude…", "Escribe a Claude…"),
        "attach_help": ("Joindre des fichiers", "Attach files", "Dateien anhängen", "Anexar ficheiros", "Adjuntar archivos"),
        "interrupt_help": ("Interrompre", "Stop", "Anhalten", "Interromper", "Detener"),
        "send_help": ("Envoyer (Retour)", "Send (Return)", "Senden (Eingabe)", "Enviar (Retorno)", "Enviar (Retorno)"),
        "model_help": ("Choisir le modèle (LLM)", "Choose the model (LLM)", "Modell (LLM) wählen", "Escolher o modelo (LLM)", "Elegir el modelo (LLM)"),
        "perm_help": ("Permissions — cliquer pour changer.", "Permissions — click to change.", "Berechtigungen — zum Ändern klicken.", "Permissões — clique para mudar.", "Permisos — clic para cambiar."),
        "effort_help": ("Effort de raisonnement — cliquer pour changer.", "Reasoning effort — click to change.", "Denkaufwand — zum Ändern klicken.", "Esforço de raciocínio — clique para mudar.", "Esfuerzo de razonamiento — clic para cambiar."),
        "instructions_help": ("Instructions .md injectées dans le prompt", ".md instructions injected into the prompt", "In den Prompt eingefügte .md-Anweisungen", "Instruções .md injetadas no prompt", "Instrucciones .md inyectadas en el prompt"),
        "effort_label": ("Effort : %@", "Effort: %@", "Aufwand: %@", "Esforço: %@", "Esfuerzo: %@"),
        "tab_general": ("Général", "General", "Allgemein", "Geral", "General"),
        "tab_diagnostics": ("Diagnostics", "Diagnostics", "Diagnose", "Diagnóstico", "Diagnóstico"),
        "tab_appearance": ("Apparence", "Appearance", "Erscheinungsbild", "Aparência", "Apariencia"),
        "max_output": ("Longueur maximale des réponses", "Maximum reply length", "Maximale Antwortlänge", "Comprimento máximo das respostas", "Longitud máxima de las respuestas"),
        "max_output_label": ("Plafond par réponse", "Cap per reply", "Obergrenze pro Antwort", "Limite por resposta", "Límite por respuesta"),
        "cli_ceiling": ("plafond du CLI", "CLI ceiling", "CLI-Obergrenze", "limite do CLI", "límite del CLI"),
        "max_output_hint": ("Écrit dans la préférence officielle de Claude Code (~/.claude/settings.json) : le réglage vaut aussi pour `claude` lancé au terminal. Le CLI refuse au-delà de 128 000 — une valeur supérieure est ramenée à 128 000 sans avertissement.", "Written to Claude Code's official preference (~/.claude/settings.json), so it also applies to `claude` run from a terminal. The CLI refuses more than 128,000 — a higher value is silently reduced to 128,000.", "Wird in die offizielle Einstellung von Claude Code geschrieben (~/.claude/settings.json) und gilt so auch für `claude` im Terminal. Das CLI lässt nicht mehr als 128.000 zu — ein höherer Wert wird stillschweigend auf 128.000 gesenkt.", "Escrito na preferência oficial do Claude Code (~/.claude/settings.json), aplicando-se também ao `claude` no terminal. O CLI recusa acima de 128 000 — um valor maior é reduzido a 128 000 sem aviso.", "Escrito en la preferencia oficial de Claude Code (~/.claude/settings.json), por lo que también se aplica a `claude` en la terminal. El CLI rechaza más de 128 000 — un valor mayor se reduce a 128 000 sin avisar."),
        "recommended": ("recommandé", "recommended", "empfohlen", "recomendado", "recomendado"),
        // Agents panel
        "conversation_still_working": ("Cette conversation travaille toujours en arrière-plan", "This conversation is still working in the background", "Diese Unterhaltung arbeitet noch im Hintergrund", "Esta conversa ainda está a trabalhar em segundo plano", "Esta conversación sigue trabajando en segundo plano"),
        "agents_panel_help": ("Afficher ou masquer le panneau des sous-agents — purement visuel, cela ne change pas leur travail.", "Show or hide the sub-agent panel — purely visual, it does not change their work.", "Das Unteragenten-Panel ein- oder ausblenden — rein visuell, ihre Arbeit ändert sich dadurch nicht.", "Mostrar ou ocultar o painel de subagentes — puramente visual, não altera o trabalho deles.", "Mostrar u ocultar el panel de subagentes — puramente visual, no cambia su trabajo."),
        "agents_title": ("Agents", "Agents", "Agenten", "Agentes", "Agentes"),
        "agents_empty": ("Aucun sous-agent dans cette conversation. Ils apparaissent quand Claude Code délègue une tâche (outil Task).", "No sub-agents in this conversation. They appear when Claude Code delegates a task (Task tool).", "Keine Sub-Agenten in dieser Unterhaltung. Sie erscheinen, wenn Claude Code eine Aufgabe delegiert (Task-Tool).", "Nenhum subagente nesta conversa. Aparecem quando o Claude Code delega uma tarefa (ferramenta Task).", "No hay subagentes en esta conversación. Aparecen cuando Claude Code delega una tarea (herramienta Task)."),
        "agent_open": ("Voir l'agent", "View agent", "Agent anzeigen", "Ver agente", "Ver agente"),
        "agent_instructions": ("Instructions", "Instructions", "Anweisungen", "Instruções", "Instrucciones"),
        "agent_activity": ("Activité", "Activity", "Aktivität", "Atividade", "Actividad"),
        "agent_result": ("Résultat", "Result", "Ergebnis", "Resultado", "Resultado"),
        "agent_running": ("en cours", "running", "läuft", "em curso", "en curso"),
        "agent_done": ("terminé", "done", "fertig", "concluído", "completado"),
        "agent_failed": ("échoué", "failed", "fehlgeschlagen", "falhou", "fallido"),
        // Model manager
        "manage_models": ("Gérer les modèles", "Manage models", "Modelle verwalten", "Gerir modelos", "Gestionar modelos"),
        "installed_models": ("Modèles installés", "Installed models", "Installierte Modelle", "Modelos instalados", "Modelos instalados"),
        "no_models": ("Aucun modèle sur ce serveur.", "No models on this server.", "Keine Modelle auf diesem Server.", "Nenhum modelo neste servidor.", "No hay modelos en este servidor."),
        "cmd_output": ("Sortie", "Output", "Ausgabe", "Saída", "Salida"),
        "cmd_placeholder": ("pull qwen3:14b", "pull qwen3:14b", "pull qwen3:14b", "pull qwen3:14b", "pull qwen3:14b"),
        "cmd_hint": ("Commandes : pull <modèle> · rm <modèle> · cp <src> <dest> · create <nom> from <base> num_ctx 32768 · fix <modèle> [as <nom>]", "Commands: pull <model> · rm <model> · cp <src> <dst> · create <name> from <base> num_ctx 32768 · fix <model> [as <name>]", "Befehle: pull <Modell> · rm <Modell> · cp <Quelle> <Ziel> · create <Name> from <Basis> num_ctx 32768 · fix <Modell> [as <Name>]", "Comandos: pull <modelo> · rm <modelo> · cp <orig> <dest> · create <nome> from <base> num_ctx 32768 · fix <modelo> [as <nome>]", "Comandos: pull <modelo> · rm <modelo> · cp <orig> <dest> · create <nombre> from <base> num_ctx 32768 · fix <modelo> [as <nombre>]"),
        // Tool-parser repair for community repacks that ship no PARSER directive.
        "repair": ("Réparer", "Repair", "Reparieren", "Reparar", "Reparar"),
        "no_tool_parser": ("Aucun analyseur d'outils intégré", "No built-in tool parser", "Kein integrierter Tool-Parser", "Sem analisador de ferramentas integrado", "Sin analizador de herramientas integrado"),
        "repair_help": ("Reconstruire ce modèle avec l'analyseur d'outils d'un modèle officiel de la même famille. L'original est conservé.", "Rebuild this model with the tool parser of an official model of the same family. The original is kept.", "Dieses Modell mit dem Tool-Parser eines offiziellen Modells derselben Familie neu erstellen. Das Original bleibt erhalten.", "Reconstruir este modelo com o analisador de ferramentas de um modelo oficial da mesma família. O original é mantido.", "Reconstruir este modelo con el analizador de herramientas de un modelo oficial de la misma familia. El original se conserva."),
        "repair_using": ("analyseur repris : %@", "borrowed parser: %@", "übernommener Parser: %@", "analisador retomado: %@", "analizador tomado: %@"),
        "repair_no_donor": ("Aucun modèle officiel de la même famille sur ce serveur pour prêter son analyseur — installez-en un (ex. qwen3.6:35b) puis réessayez.", "No official model of the same family on this server to lend its parser — install one (e.g. qwen3.6:35b) and try again.", "Kein offizielles Modell derselben Familie auf diesem Server, das seinen Parser leihen könnte — installieren Sie eines (z. B. qwen3.6:35b) und versuchen Sie es erneut.", "Nenhum modelo oficial da mesma família neste servidor para emprestar o analisador — instale um (ex.: qwen3.6:35b) e tente novamente.", "Ningún modelo oficial de la misma familia en este servidor para prestar su analizador — instale uno (p. ej. qwen3.6:35b) e inténtelo de nuevo."),
        "cmd_unknown": ("Commande inconnue — voir les exemples sous le champ.", "Unknown command — see the examples below the field.", "Unbekannter Befehl — siehe Beispiele unter dem Feld.", "Comando desconhecido — veja os exemplos sob o campo.", "Comando desconocido — mira los ejemplos bajo el campo."),
        "execute": ("Exécuter", "Run", "Ausführen", "Executar", "Ejecutar"),
        "back": ("Retour", "Back", "Zurück", "Voltar", "Atrás"),
        // Updates
        "updates": ("Mises à jour", "Updates", "Updates", "Atualizações", "Actualizaciones"),
        "update_check": ("Vérifier les mises à jour", "Check for updates", "Nach Updates suchen", "Procurar atualizações", "Buscar actualizaciones"),
        "update_checking": ("Vérification…", "Checking…", "Suche läuft…", "A verificar…", "Comprobando…"),
        "update_available": ("Version %@ disponible sur GitHub.", "Version %@ is available on GitHub.", "Version %@ ist auf GitHub verfügbar.", "A versão %@ está disponível no GitHub.", "La versión %@ está disponible en GitHub."),
        "update_uptodate": ("Vous avez la dernière version.", "You're on the latest version.", "Sie haben die neueste Version.", "Tem a versão mais recente.", "Tienes la última versión."),
        "update_download": ("Télécharger", "Download", "Laden", "Transferir", "Descargar"),
        "update_error": ("Impossible de vérifier les mises à jour.", "Couldn't check for updates.", "Updates konnten nicht geprüft werden.", "Não foi possível verificar atualizações.", "No se pudieron comprobar actualizaciones."),
        "update_repo_unreachable": ("Dépôt GitHub inaccessible (privé ou hors ligne).", "GitHub repository unreachable (private or offline).", "GitHub-Repository nicht erreichbar (privat oder offline).", "Repositório GitHub inacessível (privado ou offline).", "Repositorio de GitHub inaccesible (privado o sin conexión)."),
        // Token gauge
        "tokens_title": ("Consommation de tokens", "Token usage", "Token-Verbrauch", "Consumo de tokens", "Consumo de tokens"),
        "tokens_context": ("Contexte actuel", "Current context", "Aktueller Kontext", "Contexto atual", "Contexto actual"),
        "tokens_in": ("Entrée cumulée", "Total input", "Eingabe gesamt", "Entrada acumulada", "Entrada acumulada"),
        "tokens_out": ("Sortie cumulée", "Total output", "Ausgabe gesamt", "Saída acumulada", "Salida acumulada"),
        "tokens_help": ("Tokens de la conversation — cliquer pour le détail et la compression du contexte.", "Conversation tokens — click for details and context compaction.", "Tokens der Unterhaltung — klicken für Details und Kontext-Kompaktierung.", "Tokens da conversa — clique para detalhes e compactação do contexto.", "Tokens de la conversación — clic para detalles y compactación del contexto."),
        "compact_now": ("Compresser le contexte", "Compact the context", "Kontext kompaktieren", "Compactar o contexto", "Compactar el contexto"),
        "compact_hint": ("Résume la conversation côté Claude Code pour libérer de la place dans le contexte. L'historique affiché ici reste intact.", "Summarizes the conversation on Claude Code's side to free context space. The transcript shown here stays intact.", "Fasst die Unterhaltung auf Claude-Code-Seite zusammen, um Kontextplatz freizugeben. Das hier angezeigte Protokoll bleibt unverändert.", "Resume a conversa do lado do Claude Code para libertar espaço de contexto. O histórico mostrado aqui permanece intacto.", "Resume la conversación del lado de Claude Code para liberar espacio de contexto. El historial mostrado aquí permanece intacto."),
        "theme_mode": ("Mode d'affichage", "Display mode", "Anzeigemodus", "Modo de exibição", "Modo de visualización"),
        "theme_system": ("Automatique", "Automatic", "Automatisch", "Automático", "Automático"),
        "theme_light": ("Clair", "Light", "Hell", "Claro", "Claro"),
        "theme_dark": ("Sombre", "Dark", "Dunkel", "Escuro", "Oscuro"),
        "accent_color": ("Couleur d'accentuation", "Accent color", "Akzentfarbe", "Cor de destaque", "Color de acento"),

        // Thanks tab
        "thanks_by": ("MacCL est développé par Trano89.", "MacCL is developed by Trano89.", "MacCL wird von Trano89 entwickelt.", "O MacCL é desenvolvido por Trano89.", "MacCL está desarrollado por Trano89."),
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

        // Groups & per-conversation / project instructions
        "group": ("Groupe", "Group", "Gruppe", "Grupo", "Grupo"),
        "new_group": ("Nouveau groupe", "New group", "Neue Gruppe", "Novo grupo", "Nuevo grupo"),
        "no_group": ("Retirer du groupe", "Remove from group", "Aus Gruppe entfernen", "Remover do grupo", "Quitar del grupo"),
        "group_name": ("nom du groupe", "group name", "Gruppenname", "nome do grupo", "nombre del grupo"),
        "conv_instructions": ("Instructions de cette conversation (optionnel)", "Instructions for this conversation (optional)", "Anweisungen für diese Unterhaltung (optional)", "Instruções para esta conversa (opcional)", "Instrucciones para esta conversación (opcional)"),
        "library": ("Bibliothèque", "Library", "Bibliothek", "Biblioteca", "Biblioteca"),
        "project_md": ("Projet (CLAUDE.md)", "Project (CLAUDE.md)", "Projekt (CLAUDE.md)", "Projeto (CLAUDE.md)", "Proyecto (CLAUDE.md)"),
        "project_hint": ("Instructions du dossier de travail — Claude Code lit CLAUDE.md automatiquement dans ce dossier.", "Working-folder instructions — Claude Code reads CLAUDE.md from that folder automatically.", "Anweisungen des Arbeitsordners — Claude Code liest CLAUDE.md dort automatisch.", "Instruções da pasta de trabalho — o Claude Code lê o CLAUDE.md dessa pasta automaticamente.", "Instrucciones de la carpeta de trabajo — Claude Code lee CLAUDE.md de esa carpeta automáticamente."),

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
        "done_error": ("Terminé avec erreur", "Finished with error", "Mit Fehler beendet", "Concluído com erro", "Terminado con error"),
        "compacting": ("Contexte plein — compactage…", "Context full — compacting…", "Kontext voll — Komprimierung…", "Contexto cheio — compactação…", "Contexto lleno — compactando…"),
        "compact_notice": ("Limite de contexte atteinte — compactage automatique (/compact), puis renvoi du message.", "Context limit reached — auto-compacting (/compact), then re-sending the message.", "Kontextlimit erreicht — automatische Komprimierung (/compact), dann erneutes Senden.", "Limite de contexto atingido — compactação automática (/compact) e reenvio da mensagem.", "Límite de contexto alcanzado — compactación automática (/compact) y reenvío del mensaje."),
        "compacted_resend": ("Contexte compacté ✓ — renvoi du dernier message…", "Context compacted ✓ — re-sending the last message…", "Kontext komprimiert ✓ — letzte Nachricht wird erneut gesendet…", "Contexto compactado ✓ — a reenviar a última mensagem…", "Contexto compactado ✓ — reenviando el último mensaje…"),
        "compact_failed": ("Le compactage a échoué — réessayez ou démarrez une nouvelle conversation.", "Compaction failed — retry or start a new conversation.", "Komprimierung fehlgeschlagen — erneut versuchen oder neue Unterhaltung starten.", "A compactação falhou — tente novamente ou inicie uma nova conversa.", "La compactación falló — reintenta o inicia una nueva conversación."),
        // Per-conversation server (no automatic fallback: a conversation is bound to its server).
        "conv_server": ("Serveur de la conversation", "Conversation server", "Server der Unterhaltung", "Servidor da conversa", "Servidor de la conversación"),
        "change_server": ("Changer de serveur", "Change server", "Server wechseln", "Mudar de servidor", "Cambiar de servidor"),
        "server_entry_hint": ("Une adresse IP suffit : le port 11434 et http:// sont ajoutés automatiquement. « Scanner » balaie tout votre réseau local.", "An IP address is enough: port 11434 and http:// are added automatically. “Scan” sweeps your whole local network.", "Eine IP-Adresse genügt: Port 11434 und http:// werden automatisch ergänzt. „Scannen“ durchsucht Ihr gesamtes lokales Netzwerk.", "Basta um endereço IP: a porta 11434 e http:// são adicionados automaticamente. “Procurar” varre toda a sua rede local.", "Basta una dirección IP: el puerto 11434 y http:// se añaden automáticamente. “Escanear” barre toda tu red local."),
        "remove": ("Retirer", "Remove", "Entfernen", "Remover", "Quitar"),
        "discovered_servers": ("Serveurs découverts", "Discovered servers", "Gefundene Server", "Servidores descobertos", "Servidores descubiertos"),
        "loading_models": ("Chargement des modèles…", "Loading models…", "Modelle werden geladen…", "A carregar modelos…", "Cargando modelos…"),
        "apply": ("Appliquer", "Apply", "Anwenden", "Aplicar", "Aplicar"),
        "server_unreachable_blocked": ("Serveur %@ injoignable — la conversation reprendra quand il sera de retour", "Server %@ unreachable — the conversation will resume when it returns", "Server %@ nicht erreichbar — die Unterhaltung wird fortgesetzt, sobald er zurück ist", "Servidor %@ inacessível — a conversa retomará quando ele voltar", "Servidor %@ inaccesible — la conversación se reanudará cuando vuelva"),
        "server_waiting": ("En attente du serveur %@…", "Waiting for server %@…", "Warten auf Server %@…", "À espera do servidor %@…", "Esperando al servidor %@…"),
        "server_back": ("Serveur %@ de retour — vous pouvez continuer", "Server %@ is back — you can continue", "Server %@ ist zurück — Sie können fortfahren", "Servidor %@ está de volta — pode continuar", "Servidor %@ ha vuelto — puede continuar"),
        "server_changed": ("Serveur changé pour %@ — l'historique complet sera renvoyé au prochain message", "Server changed to %@ — the full history will be resent on the next message", "Server zu %@ gewechselt — der gesamte Verlauf wird mit der nächsten Nachricht erneut gesendet", "Servidor alterado para %@ — o histórico completo será reenviado na próxima mensagem", "Servidor cambiado a %@ — el historial completo se reenviará con el próximo mensaje"),
        "server_change_busy": ("Impossible de changer de serveur pendant un tour", "Cannot change server while a turn is running", "Server kann während eines Zuges nicht gewechselt werden", "Não é possível mudar de servidor durante um turno", "No se puede cambiar de servidor durante un turno"),
        "server_change_note": ("La conversation garde tout son historique : il est renvoyé intégralement au nouveau serveur au prochain message.", "The conversation keeps its whole history: it is fully resent to the new server on the next message.", "Die Unterhaltung behält ihren gesamten Verlauf: Er wird mit der nächsten Nachricht vollständig an den neuen Server gesendet.", "A conversa mantém todo o histórico: ele é reenviado integralmente ao novo servidor na próxima mensagem.", "La conversación conserva todo su historial: se reenvía íntegramente al nuevo servidor con el próximo mensaje."),
        "server_no_models_hint": ("Ce serveur ne répond pas ou n'a aucun modèle", "This server doesn't answer or has no models", "Dieser Server antwortet nicht oder hat keine Modelle", "Este servidor não responde ou não tem modelos", "Este servidor no responde o no tiene modelos"),
        "server_per_conv_note": ("Le serveur Ollama se choisit à la création de chaque conversation, et peut être changé en cours de route depuis la barre de saisie.", "The Ollama server is chosen when each conversation is created, and can be changed mid-course from the composer bar.", "Der Ollama-Server wird beim Erstellen jeder Unterhaltung gewählt und kann unterwegs in der Eingabeleiste geändert werden.", "O servidor Ollama é escolhido na criação de cada conversa e pode ser alterado a meio a partir da barra de escrita.", "El servidor Ollama se elige al crear cada conversación y puede cambiarse sobre la marcha desde la barra de escritura."),
        "waiting_local": ("%@ réfléchit… les modèles locaux peuvent être lents au premier tour.", "%@ is thinking… local models can be slow on the first turn.", "%@ denkt nach… lokale Modelle können beim ersten Durchlauf langsam sein.", "%@ está a pensar… modelos locais podem ser lentos na primeira volta.", "%@ está pensando… los modelos locales pueden ser lentos en el primer turno."),
        "waiting_remote": ("En attente de %@...", "Waiting for %@...", "Warten auf %@...", "A espera de %@...", "Esperando a %@..."),
        "still_running": ("Toujours en cours (gros modèle ou long prompt) - patientez ou cliquez sur stop.", "Still running (big model or long prompt) - wait or press stop.", "Läuft noch (großes Modell oder langer Prompt) - warten oder Stop drücken.", "Ainda em curso (modelo grande ou prompt longo) - aguarde ou toque em stop.", "Aún en curso (modelo grande o prompt largo) - espera o pulsa stop."),
        "binary_not_found": ("Binaire `claude` introuvable. Renseignez son chemin dans les Réglages (Cmd,).", "Binary `claude` not found. Set its path in Settings (Cmd,).", "Binärdatei 'claude' nicht gefunden. Pfad in den Einstellungen angeben (Cmd,).", "Binário 'claude' não encontrado. Informe o caminho nos Ajustes (Cmd,).", "Binario `claude` no encontrado. Configure su ruta en Preferencias (Cmd,)."),
        "server_error": ("Erreur serveur Ollama", "Ollama server error", "Ollama-Serverfehler", "Erro do servidor Ollama", "Error del servidor Ollama"),
        "ollama_unreachable": ("Serveur Ollama injoignable à %@. Vérifiez qu'il tourne (`ollama serve`) et que la machine est accessible.", "Ollama server unreachable at %@. Check that it's running (`ollama serve`) and the machine is reachable.", "Ollama-Server unter %@ nicht erreichbar. Prüfen Sie, ob er läuft (`ollama serve`) und die Maschine erreichbar ist.", "Servidor Ollama inacessível em %@. Verifique se está a correr (`ollama serve`) e se a máquina está acessível.", "Servidor Ollama inaccesible en %@. Comprueba que está en marcha (`ollama serve`) y que la máquina es accesible."),
        "ollama_too_old": ("Ce serveur Ollama (v%@) est trop ancien : l'API Anthropic (/v1/messages) exige la v0.14 ou plus récente. Mettez Ollama à jour.", "This Ollama server (v%@) is too old: the Anthropic API (/v1/messages) needs v0.14 or newer. Please update Ollama.", "Dieser Ollama-Server (v%@) ist zu alt: Die Anthropic-API (/v1/messages) erfordert v0.14 oder neuer. Bitte aktualisieren.", "Este servidor Ollama (v%@) é demasiado antigo: a API Anthropic (/v1/messages) requer a v0.14 ou mais recente. Atualize o Ollama.", "Este servidor Ollama (v%@) es demasiado antiguo: la API de Anthropic (/v1/messages) requiere la v0.14 o posterior. Actualiza Ollama."),
        "ollama_tuning": ("Réglages du serveur Ollama", "Ollama server settings", "Ollama-Servereinstellungen", "Definições do servidor Ollama", "Ajustes del servidor Ollama"),
        "ollama_tuning_note": ("Le contexte effectif est le plus PETIT de trois plafonds : le maximum du modèle (affiché dans le sélecteur de modèles), OLLAMA_CONTEXT_LENGTH côté serveur, et la RAM. Mesuré ici : 256k tokens sur un modèle 35b ≈ 47 Go. Pour viser 1 M de tokens : un modèle qui le supporte nativement (ex. llama4:scout — 10 M), OLLAMA_CONTEXT_LENGTH=1000000, et la quantification du cache KV (flash attention + q8_0 divise la RAM du contexte par ~2, q4_0 par ~4). À poser avant `ollama serve` :", "The effective context is the SMALLEST of three ceilings: the model's maximum (shown in the model picker), OLLAMA_CONTEXT_LENGTH on the server, and RAM. Measured here: 256k tokens on a 35b model ≈ 47 GB. To aim for 1M tokens: a model that natively supports it (e.g. llama4:scout — 10M), OLLAMA_CONTEXT_LENGTH=1000000, and KV-cache quantization (flash attention + q8_0 halves context RAM, q4_0 quarters it). Set before `ollama serve`:", "Der effektive Kontext ist der KLEINSTE von drei Grenzen: das Maximum des Modells (im Modellwähler angezeigt), OLLAMA_CONTEXT_LENGTH auf dem Server und der RAM. Gemessen: 256k Tokens auf einem 35b-Modell ≈ 47 GB. Für 1 M Tokens: ein Modell, das dies nativ unterstützt (z. B. llama4:scout — 10 M), OLLAMA_CONTEXT_LENGTH=1000000 und KV-Cache-Quantisierung (Flash Attention + q8_0 halbiert den Kontext-RAM, q4_0 viertelt ihn). Vor `ollama serve` setzen:", "O contexto efetivo é o MENOR de três limites: o máximo do modelo (mostrado no seletor de modelos), OLLAMA_CONTEXT_LENGTH no servidor e a RAM. Medido: 256k tokens num modelo 35b ≈ 47 GB. Para 1 M de tokens: um modelo que o suporte nativamente (ex. llama4:scout — 10 M), OLLAMA_CONTEXT_LENGTH=1000000 e quantização do cache KV (flash attention + q8_0 reduz a RAM do contexto para metade, q4_0 para um quarto). Definir antes de `ollama serve`:", "El contexto efectivo es el MENOR de tres límites: el máximo del modelo (mostrado en el selector de modelos), OLLAMA_CONTEXT_LENGTH en el servidor y la RAM. Medido: 256k tokens en un modelo 35b ≈ 47 GB. Para 1 M de tokens: un modelo que lo soporte nativamente (p. ej. llama4:scout — 10 M), OLLAMA_CONTEXT_LENGTH=1000000 y cuantización de la caché KV (flash attention + q8_0 reduce a la mitad la RAM del contexto, q4_0 a un cuarto). Definir antes de `ollama serve`:"),
        "launch_failed": ("Lancement échoué : %@", "Launch failed: %@", "Start fehlgeschlagen: %@", "Arranque falhou: %@", "Inicio falló: %@"),
        "session_terminated": ("La session `claude` s'est arrêtée (code %@).", "The `claude` session terminated (code %@).", "Die 'claude' Sitzung wurde beendet (Code %@).", "A sessão 'claude' foi encerrada (código %@).", "La sesión de `claude` terminó (código %@)."),
        "session_stopped": ("Session arrêtée", "Session stopped", "Sitzung gestoppt", "Sessão interrompida", "Sesión detenida"),
        "expand": ("Déplier", "Expand", "Ausklappen", "Expandir", "Expandir"),
        "collapse": ("Replier", "Collapse", "Einklappen", "Recolher", "Contraer"),
        "permission_pending": ("Requête de permission reçue (dialogue natif à venir).", "Permission request received (native dialog coming soon).", "Berechtigungsanfrage erhalten (nativer Dialog kommt bald).", "Pedido de permissão recebido (diálogo nativo em breve).", "Solicitud de permiso recibida (diálogo nativo próximamente)."),
        "invalid_ollama_url": ("L'URL du serveur Ollama n'est pas valide. Utilisez http:// ou https://.", "Ollama server URL is invalid. Use http:// or https://.", "Die Ollama-Server-URL ist ungültig. Verwenden Sie http:// oder https://.", "O URL do servidor Ollama é inválido. Use http:// ou https://.", "La URL del servidor Ollama es inválida. Usa http:// o https://."),

        // Agent monitor

        // Workspace panel

        // Standby servers

        // Network server warning

        // Network section

        // Standby server manual entry

        // Standby server picker sheet

        // Server health indicators

        // URL validation feedback

        // Context / predict range errors

        // Server add/remove confirmation

        // Server section headers (refactored)

        // Background/foreground auto-heal

        // Standby server picker
    ]
    // swiftlint:enable line_length
}
