package app.folio.folio_native

import java.io.IOException

// Códigos de error del contrato (docs/CONTRATOS.md §6).
internal const val ERR_PERMISSION_DENIED = "permission_denied"
internal const val ERR_UNSUPPORTED = "unsupported"
internal const val ERR_IO = "io"
internal const val ERR_OCR_FAILED = "ocr_failed"
internal const val ERR_CANCELLED = "cancelled"

internal const val ENGINE_MLKIT_LATIN = "mlkit_latin"

/** Idiomas objetivo del modelo latino incluido (reconoce también otros idiomas de alfabeto latino). */
internal val SUPPORTED_LANGUAGES = listOf("es-ES", "en-US")

/** Error con código del contrato que se devuelve a Dart como `PlatformException`. */
internal class NativeException(val code: String, override val message: String) : Exception(message)

/** Traduce un error de escritura a un mensaje legible (sin espacio, permisos…). */
internal fun writeError(e: IOException, what: String): NativeException {
    val msg = e.message.orEmpty()
    return if (msg.contains("ENOSPC") || msg.contains("No space left", ignoreCase = true)) {
        NativeException(ERR_IO, "No queda espacio suficiente en el dispositivo para guardar $what.")
    } else {
        NativeException(ERR_IO, "No se pudo guardar $what: ${msg.ifBlank { e.javaClass.simpleName }}")
    }
}
