package app.folio.folio_native

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.ArgumentMatchers.anyString
import org.mockito.ArgumentMatchers.eq
import org.mockito.ArgumentMatchers.isNull
import org.mockito.Mockito
import kotlin.test.Test

/*
 * Pruebas unitarias de las ramas del plugin que no necesitan un dispositivo.
 * Se ejecutan con `./gradlew :folio_native:testDebugUnitTest` desde android/ de la app.
 */
internal class FolioNativePluginTest {
    @Test
    fun excludeFromBackup_isNoOpTrueOnAndroid() {
        val plugin = FolioNativePlugin()
        val result: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(MethodCall("files.excludeFromBackup", mapOf("path" to "/tmp/x")), result)
        Mockito.verify(result).success(true)
    }

    @Test
    fun scanner_isUnsupportedOnAndroid() {
        val plugin = FolioNativePlugin()
        val result: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(MethodCall("scanner.scan", null), result)
        Mockito.verify(result).error(eq(ERR_UNSUPPORTED), anyString(), isNull())
    }

    @Test
    fun recognize_withoutPath_isIoError() {
        val plugin = FolioNativePlugin()
        val result: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(MethodCall("ocr.recognize", mapOf<String, Any>()), result)
        Mockito.verify(result).error(eq(ERR_IO), anyString(), isNull())
    }

    @Test
    fun unknownMethod_isNotImplemented() {
        val plugin = FolioNativePlugin()
        val result: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(MethodCall("getPlatformVersion", null), result)
        Mockito.verify(result).notImplemented()
    }
}
