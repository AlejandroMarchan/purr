# Diseño: motor en meetings, historial de dictados, postprocesado LLM y pulido de UX

**Fecha:** 2026-07-02
**Estado:** aprobado (diseño validado en conversación; pendiente de plan de ejecución)
**Alcance:** cuatro features independientes (F1–F4), cada una con su rama, PR y validación propia. Lo descartado de esta ronda vive en [`docs/BACKLOG.md`](../../BACKLOG.md).

## Contexto

Purr es una app de barra de menús para macOS (Swift/SwiftPM, AppKit + islas SwiftUI) de dictado 100 % local. Tres carencias detectadas en investigación de código (referencias `file:line` verificadas el 2026-07-02):

1. El modo meeting ignora el setting Engine: `AppCoordinator` inyecta un `ParakeetEngine` concreto (`AppCoordinator.swift:115`, `:181`) y `MeetingPipeline` llama a su `transcribeDetailed` fuera del protocolo (`MeetingPipeline.swift:36`, `:204`). Parakeet TDT v2 es English-only → no hay reuniones en español.
2. No existe historial: el audio se descarta en `AudioRecorder.stop()` (`AudioRecorder.swift:157`) y el texto solo pasa por `os.log` a nivel debug. Si `engine.transcribe` lanza, el audio ya se perdió (`AppCoordinator.swift:589` vs `:635`).
3. El postprocesado es 100 % determinista (`PostProcessor.swift`: fillers → voice commands → diccionario → espaciado) sin opción de limpieza/reescritura con LLM ni instrucciones del usuario.

Referencia de UX: Wispr Flow (docs.wisprflow.ai). Patrones adoptados: entradas fallidas como filas de primera clase con Retry, "Undo AI edit" (crudo ↔ pulido), audio con TTL, niveles planos de limpieza.

## Decisiones cerradas

| # | Decisión | Valor |
|---|----------|-------|
| 1 | Retención de audio del historial | 7 días por defecto; configurable (Nunca / 24 h / 7 días / 30 días). El texto se conserva siempre hasta borrado manual. |
| 2 | Selección de motor en meetings | Selector propio en Settings > Features > Meeting Mode, independiente del engine de dictado. |
| 3 | Postprocesado LLM por defecto | `Off` (opt-in). El comportamiento actual no cambia para nadie. |
| 4 | Acceso al historial | Ventana dedicada (item nuevo en menú de barra) + tab "History" en Settings que muestra la misma vista. |

---

## F1 — Motor seleccionable en meeting mode

**Objetivo:** poder transcribir reuniones en español eligiendo motor sin tocar el engine del dictado.

### Diseño

- **Protocolo.** Extender `TranscriptionEngine` (`TranscriptionEngine.swift:9`) con una variante detallada engine-agnóstica:
  ```swift
  struct DetailedTranscription {
      struct TimedToken { let text: String; let start: TimeInterval; let end: TimeInterval }
      let text: String
      let tokens: [TimedToken]   // vacío si el motor no da timings
  }
  func transcribeDetailed(samples: [Float]) async throws -> DetailedTranscription
  ```
  `ParakeetEngine` adapta su `ASRResult` actual (`ParakeetEngine.swift:257`); `WhisperEngine` activa `wordTimestamps: true` (`WhisperEngine.swift:77`) y mapea word timings a `TimedToken`.
- **Setting.** Nueva clave `meeting.engine` en `SettingsStore` (mismo patrón `Keys` + `@Published` con `didSet`), reutilizando `SettingsStore.Engine`. Default: `.parakeet` (comportamiento actual).
- **Inyección.** `AppCoordinator` construye el motor de meeting según `meeting.engine` y lo pasa a `MeetingPipeline` tipado como `any TranscriptionEngine` (hoy `ParakeetEngine` concreto). El `switch` replica `rebuildEngine` (`AppCoordinator.swift:372-383`).
- **MeetingDocument.** El merge speaker↔texto (`MeetingDocument.swift:126-158`, `speakerAt` `:282`) consume `DetailedTranscription.tokens` en vez de `ASRResult.tokenTimings`. La cabecera Markdown deja de hardcodear "Parakeet TDT v2" (`:38`, `:81`) y muestra el motor real.
- **Degradación.** Si el motor devuelve `tokens` vacío en modo dual-track, el transcript se genera sin atribución por speaker (formato mic-only) y la cabecera lo indica. Nunca se falla la reunión entera por falta de timings.
- **UI.** `Picker("Meeting engine")` en la sección Meeting Mode de `featuresTab` (`SettingsView.swift:263-316`), con la misma UX de descarga de modelo que el Engine tab.
- **Spike previo (timebox 2 h):** verificar si FluidAudio 0.8 permite cargar Parakeet TDT **v3 multilingüe** (el comentario de `Package.swift:12-14` lo sugiere) manteniendo timings. Si sí, se añade como tercera opción del picker ("Parakeet v3 (multilingüe)") — sería la vía más rápida para español. El spike no bloquea el resto de F1.

### Validación
Reunión de prueba en español con Whisper (modelo multilingüe) → transcript con speakers correctos; reunión en inglés con Parakeet → sin regresión; picker persiste tras reinicio.

---

## F2 — Historial de dictados (con Recover y estadísticas)

**Objetivo:** ningún dictado se pierde: fallos reintentables, texto re-copiable, audio recuperable.

### Modelo de datos

`HistoryStore`: `@MainActor final class HistoryStore: ObservableObject { static let shared }` (patrón `SettingsStore`).

```swift
struct DictationEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let duration: TimeInterval
    var rawText: String?        // salida del ASR, pre-postprocesado
    var processedText: String?  // lo que se insertó/copió
    let engineUsed: String      // "parakeet" | "whisper:<model>"
    let mode: Mode              // batch | streaming
    var status: Status          // ok | failed(message) | interrupted | cancelled
    var audioFilename: String?  // nil si el audio ya expiró o retención = Nunca
}
```

- **Persistencia:** `~/Library/Application Support/Purr/History/history.json` (escritura atómica, patrón `MeetingDocument.write`, `MeetingDocument.swift:220-249`) + WAVs 16 kHz mono en `History/audio/<uuid>.wav`. Sin CoreData/SwiftData (el proyecto no los usa). Tope de seguridad: 1 000 entradas de texto (FIFO).
- **Retención de audio:** setting `history.audioRetention` (Nunca / 24 h / 7 días — default / 30 días). Barrido al arrancar y una vez al día; borra WAVs vencidos y anula `audioFilename`.

### Puntos de captura (orden crítico)

- **Batch** (`AppCoordinator.finishBatchRecording`, `:584-664`): tras `recorder.stop()` (`:589`) se crea la entrada y **se escribe el WAV antes de llamar a `engine.transcribe`** (`:635`). Éxito → se rellenan `rawText`/`processedText`; excepción → `status = .failed` con el WAV ya a salvo. Escritura de WAV en cola de background para no añadir latencia al hot path.
- **Streaming** (`runStreamingTask`, `:745-801`): el WAV se escribe incrementalmente desde los `chunks`; el texto se consolida desde `committed` al cerrar.
- **Recover (QoL):** entrada con WAV pero sin texto y sin cierre limpio (quit/crash a mitad de dictado) → al arrancar se marca `interrupted` y aparece destacada con botón Retry. Sale gratis del orden "WAV primero".
- **Esc/cancelado** (F4): `status = .cancelled`, WAV conservado según retención.

### UI

- **Ventana "History"** dedicada (`NSWindow` + `NSHostingController`, patrón `AppDelegate.showSettings()` `AppDelegate.swift:92-109`, cacheada como `historyWindow`). Item "History…" en el menú de barra (`MenuBarController.rebuildMenu()`, junto a `MenuBarController.swift:62`).
- **Lista** (más reciente arriba): texto (procesado por defecto), fecha relativa, duración, motor, badge de estado. Fallos/interrumpidos destacados (naranja) con **Retry** inline.
- **Acciones por entrada:** Copiar (reutiliza `copyToClipboard`, `AppCoordinator.swift:876`) · Retry con selector de motor (re-ejecuta transcripción + postprocesado sobre el WAV; el resultado actualiza la entrada, no inserta texto en otras apps) · Ver crudo ↔ pulido · Exportar audio (save panel a .wav) · Borrar (con confirmación). Pie de ventana: "Delete all history".
- **Tarjeta de estadísticas (QoL)** en la cabecera: palabras totales dictadas, WPM medio, racha de días. Calculado on-the-fly del JSON (con 1 000 entradas es despreciable).
- **Tab "History" en Settings:** quinto tab del `TabView` (`SettingsView.swift:36-45`) embebiendo la misma `HistoryView`.

### Errores
Fallo al escribir WAV → el dictado continúa (historial degradado a solo-texto, log warning). Fallo al leer `history.json` corrupto → se renombra a `.bak` y se arranca vacío (nunca se bloquea el dictado por culpa del historial).

---

## F3 — Postprocesado LLM configurable

**Objetivo:** limpieza/reescritura opcional con LLM local e instrucciones del usuario (p. ej. "las enumeraciones, como lista con saltos de línea").

### Diseño

- **Niveles** (setting `postprocess.llmLevel`, default `Off`):
  - `Off` — pipeline determinista actual, sin cambios.
  - `Limpieza` — corrige puntuación/capitalización, elimina falsos comienzos y repeticiones, convierte enumeraciones habladas en listas con saltos de línea. **No cambia las palabras del usuario.**
  - `Reescritura` — interpreta y redacta con claridad manteniendo significado e idioma.
- **Instrucciones personalizadas** (setting `postprocess.customInstructions`, string): `TextEditor` en Settings; se añaden al prompt del nivel activo.
- **Motor:** Gemma 3 4B vía `LlamaRuntime.shared.generate` (actor existente, `LlamaRuntime.swift:15`), plantilla de chat Gemma y patrón watchdog copiados de `EditInterpreter` (`EditInterpreter.swift:172-201`, `:420-434`). Timeout 15 s → si vence, falla o el modelo no está descargado, **fallback silencioso al texto determinista** (el dictado nunca se pierde ni se retrasa indefinidamente). Parámetros iniciales: `temperature 0.2`, `maxTokens ~ 2×` los tokens de entrada.
- **Orden:** ASR → `PostProcessor.apply` determinista (fillers, comandos, diccionario) → LLM sobre el resultado (mismo orden que Voice Edit). "Scratch that" y `dropPreviousChunks` se resuelven antes del LLM.
- **Integración:** solo **modo batch**, interceptando tras `makePostProcessor().apply(raw)` (`AppCoordinator.swift:636`) y antes del insert (`:645`). HUD muestra estado "Polishing…" durante la llamada. `EditInterpreter.warmUp()` ya precalienta Gemma al pulsar la hotkey (`EditInterpreter.swift:75-87`); se reutiliza el mismo warm-up cuando el nivel ≠ Off.
- **Smart Typing:** sin LLM en esta fase (el texto ya está tecleado frase a frase; borrar-y-repegar es frágil: cursor movido, undo múltiple, Chrome/Electron). Si Smart Typing está activo y nivel ≠ Off, Settings muestra una nota "El pulido con IA se aplica solo con Smart Typing desactivado". Pase final opcional → backlog.
- **Historial:** `rawText` = salida determinista, `processedText` = salida LLM → el toggle crudo↔pulido de F2 hace de "Undo AI edit" sin trabajo extra.
- **UI:** nueva `Section("AI cleanup")` en `featuresTab`, junto a Meeting summary y Voice Edit (comparten el mismo modelo Gemma y su UX de descarga/licencia, `SettingsView.swift:1088+`): picker de nivel con descripción de una línea por opción + campo de instrucciones + estado del modelo.
- **Contención del actor:** `LlamaRuntime` serializa generaciones; si hay un resumen de meeting en curso, el postprocesado esperaría → el watchdog de 15 s cubre el caso degradando a determinista.

### Validación
Dictar una enumeración ("uno… dos… tres…") con nivel Limpieza → lista con saltos de línea; con Off → comportamiento idéntico al actual; desconectar el modelo (no descargado) → fallback limpio; instrucción personalizada respetada.

---

## F4 — Pulido de experiencia

Tres mejoras pequeñas, una sola rama, validación conjunta:

1. **Esc cancela el dictado en curso.** Durante `state == .recording`, Esc (keyCode 53, vía el CGEventTap de `HotkeyManager`) descarta la transcripción: batch → no se llama al motor; streaming → se cancela la sesión sin insertar más. Con F2, la entrada queda `cancelled` con su WAV. El HUD confirma ("Cancelled").
2. **Abrir al iniciar sesión.** Toggle en Settings > General con `SMAppService.mainApp` (macOS 13+; el target es 14+). Estado leído de `SMAppService.status` para reflejar cambios hechos en System Settings.
3. **Feedback sonoro al empezar/parar grabación.** Dos cues sutiles del sistema (p. ej. `NSSound`), toggle en Settings > General (default: on). La cancelación por Esc reproduce un tercer cue distinto ("descartado") para que se distinga del stop normal. Volumen bajo, nunca por encima del audio del sistema.

Dependencia: la parte "entrada cancelled en historial" de (1) requiere F2; si F4 se ejecutara antes, Esc simplemente descarta.

---

## Orden de ejecución y dependencias

```
F1 (motor meetings)        — independiente, la más pequeña
F2 (historial + recover)   — independiente de F1
F3 (postprocesado LLM)     — usa el esquema raw/processed de F2 (solo el modelo de datos)
F4 (pulido UX)             — Esc→historial usa F2; login/sonido independientes
```

Secuencia: **F1 → F2 → F3 → F4**. Cada feature: rama propia sobre `main` del fork, PR, validación manual (UAT) antes de empezar la siguiente.

## Fuera de alcance (→ `docs/BACKLOG.md`)

Transcripción de ficheros arrastrados, snippets hablados, grabador de hotkey custom, context awareness, estilos por categoría de app, auto-add al diccionario, pase LLM final para Smart Typing, reproducción inline de audio en el historial.

## Nota de entorno

En esta máquina no hay Xcode (solo CLT), así que los bloques `#if canImport(FoundationModels)` no compilan (macros `@Generable`). El build local usa el workaround documentado en la conversación (guards temporales). Ninguna feature de este diseño depende de FoundationModels: F3 usa Gemma directamente.
