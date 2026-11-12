package app.folio.folio_native

import android.app.ActivityManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicInteger

/**
 * Adaptadores nativos de Folio para Android (docs/CONTRATOS.md §6).
 *
 * Canal `folio/native`. Todo el trabajo pesado (decodificar imágenes, OCR, renderizar PDF, escribir
 * ficheros) se ejecuta en ejecutores de fondo; los resultados se entregan en el hilo principal.
 */
class FolioNativePlugin :
    FlutterPlugin,
    MethodCallHandler {

    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Un hilo para OCR (el reconocedor de ML Kit se crea y usa siempre desde él) y otro para PDF
    // (PdfRenderer no admite uso concurrente). Así el OCR de una página no bloquea el render de otra.
    private var ocrExecutor: ExecutorService? = null
    private var pdfExecutor: ExecutorService? = null
    private var ocr: TextRecognizerAdapter? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        appContext = context
        ocr = TextRecognizerAdapter(context)
        ocrExecutor = Executors.newSingleThreadExecutor(NamedThreadFactory("folio-ocr"))
        pdfExecutor = Executors.newSingleThreadExecutor(NamedThreadFactory("folio-pdf"))
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        val adapter = ocr
        val ocrExec = ocrExecutor
        if (adapter != null && ocrExec != null) {
            try {
                ocrExec.execute { adapter.close() }
            } catch (_: RejectedExecutionException) {
                adapter.close()
            }
        }
        ocrExec?.shutdown()
        pdfExecutor?.shutdown()
        ocrExecutor = null
        pdfExecutor = null
        ocr = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "ocr.recognize" -> {
                val path = call.argument<String>("path")
                val adapter = ocr
                if (path.isNullOrBlank()) {
                    result.error(ERR_IO, "Falta la ruta de la imagen.", null)
                    return
                }
                if (adapter == null) {
                    result.error(ERR_UNSUPPORTED, "El reconocimiento de texto no está disponible.", null)
                    return
                }
                runInBackground(ocrExecutor, result) { adapter.recognize(path) }
            }

            "ocr.info" -> result.success(
                mapOf(
                    "engine" to ENGINE_MLKIT_LATIN,
                    "languages" to SUPPORTED_LANGUAGES,
                    "handwriting" to false,
                    "available" to (ocr != null),
                )
            )

            "pdf.pageCount" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error(ERR_IO, "Falta la ruta del PDF.", null)
                    return
                }
                runInBackground(pdfExecutor, result) { PdfAdapter.pageCount(path) }
            }

            "pdf.renderPage" -> {
                val path = call.argument<String>("path")
                val outPath = call.argument<String>("outPath")
                val page = call.argument<Number>("page")?.toInt()
                val targetWidth = call.argument<Number>("targetWidth")?.toInt() ?: DEFAULT_RENDER_WIDTH
                if (path.isNullOrBlank() || outPath.isNullOrBlank() || page == null) {
                    result.error(ERR_IO, "Faltan argumentos para renderizar la página.", null)
                    return
                }
                runInBackground(pdfExecutor, result) { PdfAdapter.renderPage(path, page, outPath, targetWidth) }
            }

            "pdf.pageText" -> {
                val path = call.argument<String>("path")
                val page = call.argument<Number>("page")?.toInt()
                if (path.isNullOrBlank() || page == null) {
                    result.error(ERR_IO, "Faltan argumentos para leer el texto de la página.", null)
                    return
                }
                runInBackground(pdfExecutor, result) { PdfAdapter.pageText(path, page) }
            }

            "scanner.scan" -> result.error(
                ERR_UNSUPPORTED,
                "El escáner de documentos no está disponible en Android. Usa la cámara.",
                null,
            )

            // En Android la copia de seguridad se controla con las reglas del manifiesto: no-op.
            "files.excludeFromBackup" -> result.success(true)

            "device.memory" -> {
                val context = appContext
                val manager = context?.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                if (manager == null) {
                    result.error(ERR_UNSUPPORTED, "No se pudo consultar la memoria del dispositivo.", null)
                    return
                }
                val info = ActivityManager.MemoryInfo()
                manager.getMemoryInfo(info)
                result.success(mapOf("total" to info.totalMem, "available" to info.availMem))
            }

            else -> result.notImplemented()
        }
    }

    /** Ejecuta [block] en [executor] y entrega su resultado (o el error traducido) en el hilo principal. */
    private fun runInBackground(executor: ExecutorService?, result: Result, block: () -> Any?) {
        if (executor == null) {
            result.error(ERR_IO, "El complemento nativo no está activo.", null)
            return
        }
        try {
            executor.execute {
                val outcome: Any? = try {
                    block()
                } catch (e: NativeException) {
                    e
                } catch (e: OutOfMemoryError) {
                    NativeException(ERR_IO, "No hay memoria suficiente para procesar el fichero.")
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                    NativeException(ERR_CANCELLED, "Operación interrumpida.")
                } catch (e: Exception) {
                    NativeException(ERR_IO, e.message ?: e.javaClass.simpleName)
                }
                mainHandler.post {
                    if (outcome is NativeException) {
                        result.error(outcome.code, outcome.message, null)
                    } else {
                        result.success(outcome)
                    }
                }
            }
        } catch (e: RejectedExecutionException) {
            result.error(ERR_IO, "El complemento nativo se está cerrando.", null)
        }
    }

    private class NamedThreadFactory(private val prefix: String) : ThreadFactory {
        private val counter = AtomicInteger(0)
        override fun newThread(r: Runnable): Thread =
            Thread(r, "$prefix-${counter.incrementAndGet()}").apply { isDaemon = true }
    }

    companion object {
        const val CHANNEL = "folio/native"
        const val DEFAULT_RENDER_WIDTH = 1700
    }
}
