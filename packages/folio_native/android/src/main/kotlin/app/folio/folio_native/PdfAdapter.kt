package app.folio.folio_native

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Acceso a PDF con [PdfRenderer]. No es seguro para uso concurrente: se llama siempre desde un único
 * hilo de fondo. Cada operación abre y cierra su propio renderer.
 */
internal object PdfAdapter {

    private const val MIN_WIDTH = 64
    private const val MAX_WIDTH = 4096
    private const val MAX_SIDE = 8192

    fun pageCount(path: String): Int = withRenderer(path) { it.pageCount }

    fun renderPage(path: String, pageIndex: Int, outPath: String, targetWidth: Int): Map<String, Any?> =
        withRenderer(path) { renderer ->
            if (pageIndex < 0 || pageIndex >= renderer.pageCount) {
                throw NativeException(ERR_IO, "La página ${pageIndex + 1} no existe en el PDF.")
            }
            renderer.openPage(pageIndex).use { page ->
                val pageWidth = max(page.width, 1)
                val pageHeight = max(page.height, 1)
                var scale = targetWidth.coerceIn(MIN_WIDTH, MAX_WIDTH).toFloat() / pageWidth
                if (pageHeight * scale > MAX_SIDE) scale = MAX_SIDE.toFloat() / pageHeight
                val width = (pageWidth * scale).roundToInt().coerceAtLeast(1)
                val height = (pageHeight * scale).roundToInt().coerceAtLeast(1)

                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                try {
                    // PdfRenderer dibuja con transparencia: fondo blanco explícito.
                    bitmap.eraseColor(Color.WHITE)
                    val matrix = Matrix().apply { setScale(scale, scale) }
                    page.render(bitmap, null, matrix, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    writePng(bitmap, File(outPath))
                } finally {
                    bitmap.recycle()
                }
                mapOf("path" to outPath, "width" to width, "height" to height)
            }
        }

    /** Texto de la página con la API de Android 15 (API 35); en versiones anteriores, cadena vacía. */
    fun pageText(path: String, pageIndex: Int): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) return ""
        return withRenderer(path) { renderer ->
            if (pageIndex < 0 || pageIndex >= renderer.pageCount) {
                throw NativeException(ERR_IO, "La página ${pageIndex + 1} no existe en el PDF.")
            }
            renderer.openPage(pageIndex).use { page ->
                page.textContents.joinToString("\n") { it.text }.trim()
            }
        }
    }

    private fun <T> withRenderer(path: String, block: (PdfRenderer) -> T): T {
        val file = File(path)
        if (!file.isFile) throw NativeException(ERR_IO, "No se encuentra el PDF.")
        val descriptor = try {
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        } catch (e: IOException) {
            throw NativeException(ERR_IO, "No se pudo abrir el PDF: ${e.message ?: "error de lectura"}")
        }
        // PdfRenderer toma posesión del descriptor y lo cierra al cerrarse.
        val renderer = try {
            PdfRenderer(descriptor)
        } catch (e: SecurityException) {
            descriptor.close()
            throw NativeException(ERR_IO, "El PDF está protegido con contraseña.")
        } catch (e: IOException) {
            descriptor.close()
            throw NativeException(ERR_IO, "El PDF está dañado o no es compatible.")
        }
        try {
            return block(renderer)
        } finally {
            renderer.close()
        }
    }

    private fun writePng(bitmap: Bitmap, out: File) {
        val parent = out.parentFile
        if (parent != null && !parent.isDirectory && !parent.mkdirs()) {
            throw NativeException(ERR_IO, "No se pudo crear la carpeta de destino.")
        }
        // Escritura atómica: fichero temporal + renombrado (nunca queda un PNG a medias en la caché).
        val tmp = File(parent, ".${out.name}.${System.nanoTime()}.tmp")
        try {
            FileOutputStream(tmp).use { stream ->
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)) {
                    throw NativeException(ERR_IO, "No se pudo codificar la página como PNG.")
                }
                stream.fd.sync()
            }
            if (out.exists()) out.delete()
            if (!tmp.renameTo(out)) throw IOException("rename failed")
        } catch (e: IOException) {
            tmp.delete()
            throw writeError(e, "la página")
        } catch (e: NativeException) {
            tmp.delete()
            throw e
        }
    }
}
