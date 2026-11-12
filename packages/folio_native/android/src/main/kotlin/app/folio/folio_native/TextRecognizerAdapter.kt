package app.folio.folio_native

import android.content.Context
import android.net.Uri
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.common.MlKitException
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.io.File
import java.io.IOException
import java.util.concurrent.ExecutionException

/**
 * OCR con ML Kit Text Recognition v2 (alfabeto latino, modelo incluido en la app).
 *
 * Todas las llamadas deben hacerse desde el mismo hilo de fondo (nunca el principal):
 * [InputImage.fromFilePath] decodifica la imagen y [Tasks.await] bloquea hasta el resultado.
 */
internal class TextRecognizerAdapter(private val context: Context) {

    private var recognizer: TextRecognizer? = null

    private fun client(): TextRecognizer =
        recognizer ?: TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS).also { recognizer = it }

    fun recognize(path: String): Map<String, Any?> {
        val file = File(path)
        if (!file.isFile) throw NativeException(ERR_IO, "No se encuentra la imagen que se quería reconocer.")

        // fromFilePath lee la orientación EXIF y la expone en rotationDegrees.
        val image = try {
            InputImage.fromFilePath(context, Uri.fromFile(file))
        } catch (e: IOException) {
            throw NativeException(ERR_IO, "No se pudo leer la imagen: ${e.message ?: "formato no compatible"}")
        }

        val text: Text = try {
            Tasks.await(client().process(image))
        } catch (e: ExecutionException) {
            val cause = e.cause
            val detail = (cause as? MlKitException)?.message ?: cause?.message ?: e.message
            throw NativeException(ERR_OCR_FAILED, "El reconocimiento de texto falló: ${detail ?: "error desconocido"}")
        }

        return toMap(text, image)
    }

    fun close() {
        recognizer?.close()
        recognizer = null
    }

    private fun toMap(text: Text, image: InputImage): Map<String, Any?> {
        // Las cajas de ML Kit están en el sistema de coordenadas de la imagen ya rotada (vertical);
        // InputImage.width/height son las dimensiones del bitmap sin rotar.
        val quarter = image.rotationDegrees == 90 || image.rotationDegrees == 270
        val imageWidth = (if (quarter) image.height else image.width).coerceAtLeast(1).toDouble()
        val imageHeight = (if (quarter) image.width else image.height).coerceAtLeast(1).toDouble()

        val lines = ArrayList<Map<String, Any?>>()
        val blocks = ArrayList<String>()
        var confidenceSum = 0.0
        var confidenceCount = 0

        for (block in text.textBlocks) {
            val blockLines = ArrayList<String>()
            for (line in block.lines) {
                val lineText = line.text.trim()
                if (lineText.isEmpty()) continue
                blockLines.add(lineText)

                val entry = HashMap<String, Any?>()
                entry["text"] = lineText
                val box = line.boundingBox
                if (box != null) {
                    val left = (box.left / imageWidth).coerceIn(0.0, 1.0)
                    val top = (box.top / imageHeight).coerceIn(0.0, 1.0)
                    val right = (box.right / imageWidth).coerceIn(0.0, 1.0)
                    val bottom = (box.bottom / imageHeight).coerceIn(0.0, 1.0)
                    entry["x"] = left
                    entry["y"] = top
                    entry["w"] = (right - left).coerceAtLeast(0.0)
                    entry["h"] = (bottom - top).coerceAtLeast(0.0)
                } else {
                    entry["x"] = 0.0
                    entry["y"] = 0.0
                    entry["w"] = 0.0
                    entry["h"] = 0.0
                }
                val confidence = line.confidence.toDouble()
                if (!confidence.isNaN() && confidence > 0.0) {
                    entry["confidence"] = confidence.coerceIn(0.0, 1.0)
                    confidenceSum += confidence.coerceIn(0.0, 1.0)
                    confidenceCount++
                }
                lines.add(entry)
            }
            if (blockLines.isNotEmpty()) blocks.add(blockLines.joinToString("\n"))
        }

        val result = HashMap<String, Any?>()
        result["text"] = blocks.joinToString("\n\n")
        result["engine"] = ENGINE_MLKIT_LATIN
        if (confidenceCount > 0) result["confidence"] = confidenceSum / confidenceCount
        result["lines"] = lines
        return result
    }
}
