package com.example.cmbok_app

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.view.KeyEvent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    private val channel = "cmbok/platform"
    private var methodChannel: MethodChannel? = null
    private var volumeKeyNavEnabled = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
        methodChannel!!.setMethodCallHandler { call, result ->
                when (call.method) {
                    "openDir" -> {
                        val path = call.argument<String>("path") ?: ""
                        result.success(openDirectory(path))
                    }
                    "openFile" -> {
                        val path = call.argument<String>("path") ?: ""
                        val mime = call.argument<String>("mimeType") ?: "*/*"
                        result.success(openFile(path, mime))
                    }
                    "getApkPath" -> result.success(getApkPath())
                    "setVolumeKeyNav" -> {
                        volumeKeyNavEnabled = call.argument<Boolean>("enabled") ?: false
                        result.success(true)
                    }
                    "pdfOpen" -> {
                        val path = call.argument<String>("path") ?: ""
                        // 可能几百页，放线程避免卡 UI
                        Thread {
                            try {
                                result.success(pdfOpen(path))
                            } catch (e: Exception) {
                                result.error("pdf_open_error", e.message, null)
                            }
                        }.start()
                    }
                    "pdfRenderPage" -> {
                        val path = call.argument<String>("path") ?: ""
                        val index = call.argument<Int>("index") ?: 0
                        val targetWidth = call.argument<Int>("targetWidth") ?: 1080
                        Thread {
                            try {
                                result.success(pdfRenderPage(path, index, targetWidth))
                            } catch (e: Exception) {
                                result.error("pdf_render_error", e.message, null)
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** 音量键翻页：开启时消费音量上/下键（阻止系统调音量）并发事件给 Dart。 */
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (volumeKeyNavEnabled && (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)) {
            methodChannel?.invokeMethod("onVolumeKey", if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) "up" else "down")
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (volumeKeyNavEnabled && (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)) {
            return true
        }
        return super.onKeyUp(keyCode, event)
    }

    /** 打开目录：ACTION_VIEW + vnd.android.document/directory（FileProvider 授权） */
    private fun openDirectory(path: String): Boolean {
        return try {
            val dir = File(path)
            if (!dir.exists()) return false
            val uri = FileProvider.getUriForFile(this, "${packageName}.fileprovider", dir)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "vnd.android.document/directory")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** 取本应用 APK 路径（applicationInfo.sourceDir） */
    private fun getApkPath(): String? {
        return try {
            packageManager.getPackageInfo(packageName, 0).applicationInfo?.sourceDir
        } catch (e: Exception) {
            null
        }
    }

    /** 用外部应用打开文件：ACTION_VIEW + FileProvider 授权（按 mimeType 选阅读器）。
     *  无可用应用抛 ActivityNotFoundException -> 返回 false（Dart 侧 toast 提示）。 */
    private fun openFile(path: String, mimeType: String): Boolean {
        return try {
            val file = File(path)
            if (!file.exists()) return false
            val uri = FileProvider.getUriForFile(this, "${packageName}.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, if (mimeType.isEmpty()) "*/*" else mimeType)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** 打开 PDF 取页数与每页像素尺寸（仅度量不渲染，供 Dart 分页度量）。 */
    private fun pdfOpen(path: String): Map<String, Any> {
        val file = File(path)
        if (!file.exists()) throw IllegalArgumentException("文件不存在: $path")
        val pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        val renderer = PdfRenderer(pfd)
        try {
            val pageCount = renderer.pageCount
            val sizes = ArrayList<Map<String, Int>>(pageCount)
            for (i in 0 until pageCount) {
                val page = renderer.openPage(i)
                sizes.add(mapOf("w" to page.width, "h" to page.height))
                page.close()
            }
            return mapOf("pageCount" to pageCount, "sizes" to sizes)
        } finally {
            renderer.close()
            pfd.close()
        }
    }

    /** 光栅化 PDF 单页为 JPEG 字节（按 targetWidth 缩放，白底），供图书阅读器按需加载。 */
    private fun pdfRenderPage(path: String, index: Int, targetWidth: Int): ByteArray {
        val file = File(path)
        if (!file.exists()) throw IllegalArgumentException("文件不存在: $path")
        val pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        val renderer = PdfRenderer(pfd)
        try {
            if (index < 0 || index >= renderer.pageCount) {
                throw IllegalArgumentException("页码越界: $index / ${renderer.pageCount}")
            }
            val page = renderer.openPage(index)
            try {
                val w = targetWidth.coerceAtLeast(1)
                val h = (w.toFloat() * page.height / page.width).toInt().coerceAtLeast(1)
                val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                // PDF 页可能透明，填白底避免夜间/浅色背景下一团黑
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val baos = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.JPEG, 85, baos)
                bitmap.recycle()
                return baos.toByteArray()
            } finally {
                page.close()
            }
        } finally {
            renderer.close()
            pfd.close()
        }
    }
}
