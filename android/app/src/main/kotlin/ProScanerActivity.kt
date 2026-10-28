package com.obddoctor.obd_doctor

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * ส่วนเสริมของหน้าหลัก ProScaner (MainActivity สืบทอดจากคลาสนี้) เพิ่มช่องทางที่ Flutter ไม่มีให้
 *
 * - proscaner/classic       : ตัวสแกน ELM327 แบบ Bluetooth Classic (SPP) ซึ่งเป็นแบบที่ขายทั่วไปมากที่สุด
 * - proscaner/classic/data  : ไบต์ที่ได้รับจากตัวสแกน
 * - proscaner/classic/scan  : อุปกรณ์ที่พบระหว่างค้นหา
 * - proscaner/net           : บังคับให้การเชื่อมต่อออกทาง Wi-Fi ของตัวสแกน แม้เปิดเน็ตมือถืออยู่
 * - proscaner/files         : บันทึก/เปิดไฟล์ผ่านหน้าต่างเลือกไฟล์ของ Android (ไฟล์สำรองข้อมูล) ไม่ต้องขอสิทธิ์ที่เก็บข้อมูล
 */
@SuppressLint("MissingPermission")
abstract class ProScanerActivity : FlutterActivity() {
    companion object {
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        private const val PERMISSION_REQUEST = 0x5C41
        private const val ENABLE_REQUEST = 0x5C42
        private const val CREATE_DOC_REQUEST = 0x5C43
        private const val OPEN_DOC_REQUEST = 0x5C44

        /** ไฟล์ที่เปิดได้ใหญ่สุด (ไฟล์สำรองข้อมูลปกติไม่กี่ MB) */
        private const val MAX_OPEN_BYTES = 64L * 1024 * 1024
    }

    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newCachedThreadPool()
    private val writer: ExecutorService = Executors.newSingleThreadExecutor()

    @Volatile private var socket: BluetoothSocket? = null

    /** เลขของการเชื่อมต่อปัจจุบัน (ฝั่งแอปส่งมา) ปิดได้เฉพาะเมื่อเลขตรงกัน */
    @Volatile private var activeToken = 0

    /** socket ที่กำลังรอเชื่อมต่อ แยกตามเลข ปิดเพื่อยกเลิกการรอได้ทันที */
    private val pendingSockets = ConcurrentHashMap<Int, BluetoothSocket>()
    private var enableResult: MethodChannel.Result? = null

    /** คำขอบันทึก/เปิดไฟล์ที่รอผู้ใช้เลือกไฟล์อยู่ (ทีละคำขอ) */
    private var createResult: MethodChannel.Result? = null
    private var createBytes: ByteArray? = null
    private var openResult: MethodChannel.Result? = null
    @Volatile private var output: OutputStream? = null
    @Volatile private var reading = false
    private var dataSink: EventChannel.EventSink? = null
    private var scanSink: EventChannel.EventSink? = null
    private var discoveryReceiver: BroadcastReceiver? = null
    private var permissionCallback: ((Boolean) -> Unit)? = null
    private val permissionQueue = ArrayDeque<Pair<Array<String>, (Boolean) -> Unit>>()

    private val btAdapter: BluetoothAdapter?
        get() = (getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "proscaner/classic").setMethodCallHandler { call, result -> onClassic(call, result) }
        MethodChannel(messenger, "proscaner/net").setMethodCallHandler { call, result -> onNet(call, result) }
        MethodChannel(messenger, "proscaner/files").setMethodCallHandler { call, result -> onFiles(call, result) }
        EventChannel(messenger, "proscaner/classic/data").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                dataSink = events
            }

            override fun onCancel(arguments: Any?) {
                dataSink = null
            }
        })
        EventChannel(messenger, "proscaner/classic/scan").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                scanSink = events
                startDiscovery()
            }

            override fun onCancel(arguments: Any?) {
                stopDiscovery()
                scanSink = null
            }
        })
    }

    override fun onDestroy() {
        stopDiscovery()
        activeToken = 0
        abortPending(null)
        closeSocket()
        // อย่าทิ้งแอปผูกไว้กับ Wi-Fi ของตัวสแกน (ไม่มีอินเทอร์เน็ต)
        try {
            (getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)?.bindProcessToNetwork(null)
        } catch (e: Exception) {
            // ไม่เป็นไร
        }
        enableResult = null
        createResult = null
        createBytes = null
        openResult = null
        worker.shutdownNow()
        writer.shutdownNow()
        super.onDestroy()
    }

    // ---------------- สิทธิ์ ----------------

    private fun bluetoothPermissions(scan: Boolean): Array<String> = when {
        Build.VERSION.SDK_INT >= 31 ->
            if (scan) arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN)
            else arrayOf(Manifest.permission.BLUETOOTH_CONNECT)
        scan -> arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        else -> emptyArray<String>()
    }

    /** ขอสิทธิ์ทีละชุด ถ้ามีคำขอค้างอยู่ให้ต่อคิว (Android แสดงได้ทีละหน้าต่าง) */
    private fun withPermissions(perms: Array<String>, then: (Boolean) -> Unit) {
        val missing = perms.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) {
            then(true)
            return
        }
        if (permissionCallback != null) {
            permissionQueue.addLast(Pair(perms, then))
            return
        }
        permissionCallback = then
        requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST) return
        val callback = permissionCallback
        permissionCallback = null
        callback?.invoke(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
        // ทำคำขอที่ต่อคิวไว้ต่อ จนกว่าจะเจอคำขอที่ต้องเปิดหน้าต่างใหม่ หรือคิวหมด
        while (permissionCallback == null) {
            val next = permissionQueue.removeFirstOrNull() ?: break
            withPermissions(next.first, next.second)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            ENABLE_REQUEST -> {
                val r = enableResult
                enableResult = null
                r?.success(resultCode == RESULT_OK || btAdapter?.isEnabled == true)
            }
            CREATE_DOC_REQUEST -> finishCreate(resultCode, data?.data)
            OPEN_DOC_REQUEST -> finishOpen(resultCode, data?.data)
        }
    }

    // ---------------- ไฟล์ (สำรอง/กู้คืนข้อมูล) ----------------

    private fun onFiles(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "saveDocument" && call.method != "openDocument") {
            result.notImplemented()
            return
        }
        if (createResult != null || openResult != null) {
            result.error("busy", "กำลังเลือกไฟล์อยู่", null)
            return
        }
        when (call.method) {
            "saveDocument" -> {
                val name = call.argument<String>("name")
                val bytes = call.argument<ByteArray>("bytes")
                if (name.isNullOrBlank() || bytes == null) {
                    result.error("args", "ข้อมูลไฟล์ไม่ครบ", null)
                    return
                }
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = call.argument<String>("mime") ?: "application/octet-stream"
                    putExtra(Intent.EXTRA_TITLE, name)
                }
                try {
                    createResult = result
                    createBytes = bytes
                    startActivityForResult(intent, CREATE_DOC_REQUEST)
                } catch (e: Exception) {
                    createResult = null
                    createBytes = null
                    result.error("unavailable", "เครื่องนี้ไม่มีหน้าต่างเลือกที่บันทึกไฟล์", null)
                }
            }
            else -> {
                val types = call.argument<List<String>>("mimeTypes")?.filter { it.isNotBlank() } ?: emptyList()
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = if (types.size == 1) types[0] else "*/*"
                    if (types.size > 1) putExtra(Intent.EXTRA_MIME_TYPES, types.toTypedArray())
                }
                try {
                    openResult = result
                    startActivityForResult(intent, OPEN_DOC_REQUEST)
                } catch (e: Exception) {
                    openResult = null
                    result.error("unavailable", "เครื่องนี้ไม่มีหน้าต่างเลือกไฟล์", null)
                }
            }
        }
    }

    /** ผู้ใช้เลือกที่บันทึกแล้ว (หรือยกเลิก): เขียนไฟล์ในเธรดแยก แล้วตอบกลับในเธรดหลัก */
    private fun finishCreate(resultCode: Int, uri: Uri?) {
        val r = createResult ?: return
        val bytes = createBytes
        createResult = null
        createBytes = null
        if (resultCode != RESULT_OK || uri == null || bytes == null) {
            r.success(null)
            return
        }
        worker.execute {
            try {
                // "wt" = เขียนทับทั้งไฟล์ บางที่เก็บไม่รองรับ ใช้ "w" แทน
                val out = (
                    try {
                        contentResolver.openOutputStream(uri, "wt")
                    } catch (e: Exception) {
                        contentResolver.openOutputStream(uri, "w")
                    }
                    ) ?: throw IOException("เปิดไฟล์ไม่ได้")
                out.use {
                    it.write(bytes)
                    it.flush()
                }
                main.post { r.success(uri.toString()) }
            } catch (e: Exception) {
                main.post { r.error("io", "บันทึกไฟล์ไม่สำเร็จ: ${e.message}", null) }
            }
        }
    }

    /** ผู้ใช้เลือกไฟล์แล้ว (หรือยกเลิก): อ่านไฟล์ในเธรดแยก แล้วตอบกลับในเธรดหลัก */
    private fun finishOpen(resultCode: Int, uri: Uri?) {
        val r = openResult ?: return
        openResult = null
        if (resultCode != RESULT_OK || uri == null) {
            r.success(null)
            return
        }
        worker.execute {
            try {
                val bytes = contentResolver.openInputStream(uri)?.use { readLimited(it) }
                    ?: throw IOException("เปิดไฟล์ไม่ได้")
                main.post { r.success(bytes) }
            } catch (e: FileTooLarge) {
                main.post { r.error("too_large", "ไฟล์ใหญ่เกินไป (เกิน 64 MB) ไม่ใช่ไฟล์สำรองของ ProScaner", null) }
            } catch (e: Exception) {
                main.post { r.error("io", "อ่านไฟล์ไม่สำเร็จ: ${e.message}", null) }
            }
        }
    }

    private class FileTooLarge : IOException("file too large")

    private fun readLimited(input: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            total += n
            if (total > MAX_OPEN_BYTES) throw FileTooLarge()
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    private fun locationEnabled(): Boolean {
        // ตั้งแต่ Android 12 การค้นหา Bluetooth ไม่ต้องเปิดตำแหน่ง
        if (Build.VERSION.SDK_INT >= 31) return true
        val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return true
        return if (Build.VERSION.SDK_INT >= 28) {
            lm.isLocationEnabled
        } else {
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) || lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    }

    // ---------------- Bluetooth Classic ----------------

    private fun onClassic(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(btAdapter != null)
            "isEnabled" -> result.success(btAdapter?.isEnabled == true)
            "locationEnabled" -> result.success(locationEnabled())
            "ensurePermissions" -> {
                val scan = call.argument<Boolean>("scan") ?: false
                withPermissions(bluetoothPermissions(scan)) { ok -> result.success(ok) }
            }
            "requestEnable" -> withPermissions(bluetoothPermissions(false)) { ok ->
                when {
                    !ok -> result.success(false)
                    btAdapter?.isEnabled == true -> result.success(true)
                    enableResult != null -> result.success(false) // กำลังถามอยู่แล้ว
                    else -> try {
                        // รอคำตอบจากผู้ใช้ (onActivityResult) ไม่ตอบกลับทันที
                        enableResult = result
                        startActivityForResult(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), ENABLE_REQUEST)
                    } catch (e: Exception) {
                        // บางเครื่องไม่มีหน้าต่างนี้ ผู้ใช้เปิดเองได้
                        enableResult = null
                        result.success(false)
                    }
                }
            }
            "openSettings" -> {
                try {
                    startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                } catch (e: Exception) {
                    // ไม่มีหน้าตั้งค่า Bluetooth (ไม่น่าเกิด)
                }
                result.success(null)
            }
            "bonded" -> withPermissions(bluetoothPermissions(false)) { ok ->
                val adapter = btAdapter
                if (!ok || adapter == null) {
                    result.error("permission", "ไม่ได้รับสิทธิ์ใช้ Bluetooth", null)
                } else {
                    val list = try {
                        adapter.bondedDevices
                            ?.filter { safeType(it) != BluetoothDevice.DEVICE_TYPE_LE }
                            ?.map { deviceMap(it) }
                            ?: emptyList()
                    } catch (e: SecurityException) {
                        emptyList()
                    }
                    result.success(list)
                }
            }
            "connect" -> {
                val address = call.argument<String>("address")
                val token = call.argument<Int>("token") ?: 0
                if (address == null) {
                    result.error("args", "ไม่มีที่อยู่อุปกรณ์", null)
                    return
                }
                withPermissions(bluetoothPermissions(false)) { ok ->
                    if (!ok) {
                        result.error("permission", "ไม่ได้รับสิทธิ์ใช้ Bluetooth (อุปกรณ์ใกล้เคียง)", null)
                    } else {
                        activeToken = token
                        worker.execute { connect(address, token, result) }
                    }
                }
            }
            "write" -> {
                val bytes = call.arguments as? ByteArray
                val out = output
                if (bytes == null || out == null) {
                    result.error("closed", "ยังไม่ได้เชื่อมต่อ", null)
                    return
                }
                writer.execute {
                    try {
                        out.write(bytes)
                        out.flush()
                        main.post { result.success(null) }
                    } catch (e: IOException) {
                        main.post { result.error("io", "ส่งข้อมูลไป Bluetooth ไม่สำเร็จ: ${e.message}", null) }
                    }
                }
            }
            "disconnect" -> {
                val token = call.argument<Int>("token")
                // ปิดเฉพาะการเชื่อมต่อของตัวที่สั่ง การเชื่อมต่อเก่าที่ถูกยกเลิกแล้วห้ามไปปิดของใหม่
                if (token == null || token == activeToken) {
                    activeToken = 0
                    abortPending(null)
                    closeSocket()
                } else {
                    abortPending(token)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun safeType(d: BluetoothDevice): Int = try {
        d.type
    } catch (e: SecurityException) {
        BluetoothDevice.DEVICE_TYPE_UNKNOWN
    }

    private fun deviceMap(d: BluetoothDevice): Map<String, Any?> {
        val name = try {
            d.name
        } catch (e: SecurityException) {
            null
        }
        val bonded = try {
            d.bondState == BluetoothDevice.BOND_BONDED
        } catch (e: SecurityException) {
            false
        }
        return mapOf("address" to d.address, "name" to name, "bonded" to bonded, "type" to safeType(d))
    }

    /** ยกเลิก socket ที่กำลังรอเชื่อมต่อ ([token] = null คือทุกตัว) */
    private fun abortPending(token: Int?) {
        val list = if (token == null) {
            pendingSockets.values.toList().also { pendingSockets.clear() }
        } else {
            listOfNotNull(pendingSockets.remove(token))
        }
        for (s in list) {
            try {
                s.close()
            } catch (e: IOException) {
                // ปิดไปแล้ว
            }
        }
    }

    private fun cancelled(result: MethodChannel.Result) {
        main.post { result.error("cancelled", "ยกเลิกการเชื่อมต่อแล้ว", null) }
    }

    /** เปิดช่อง SPP ลองหลายวิธี เพราะตัวสแกนก๊อปบางรุ่นไม่ตอบแบบมาตรฐาน */
    private fun connect(address: String, token: Int, result: MethodChannel.Result) {
        closeSocket()
        val adapter = btAdapter
        if (adapter == null) {
            main.post { result.error("unavailable", "เครื่องนี้ไม่มี Bluetooth", null) }
            return
        }
        if (!adapter.isEnabled) {
            main.post { result.error("off", "Bluetooth ปิดอยู่ เปิด Bluetooth แล้วลองใหม่", null) }
            return
        }
        try {
            if (adapter.isDiscovering) adapter.cancelDiscovery()
        } catch (e: SecurityException) {
            // ไม่มีสิทธิ์หยุดค้นหา ไม่เป็นไร
        }
        val device = try {
            adapter.getRemoteDevice(address)
        } catch (e: IllegalArgumentException) {
            main.post { result.error("args", "ที่อยู่อุปกรณ์ไม่ถูกต้อง", null) }
            return
        }
        val attempts: List<() -> BluetoothSocket> = listOf(
            { device.createRfcommSocketToServiceRecord(SPP_UUID) },
            { device.createInsecureRfcommSocketToServiceRecord(SPP_UUID) },
            {
                device.javaClass.getMethod("createRfcommSocket", Int::class.javaPrimitiveType!!)
                    .invoke(device, 1) as BluetoothSocket
            },
        )
        var lastError: Exception? = null
        for (make in attempts) {
            if (activeToken != token) {
                cancelled(result)
                return
            }
            var s: BluetoothSocket? = null
            try {
                s = make()
                pendingSockets[token] = s
                s.connect()
                pendingSockets.remove(token)
                if (activeToken != token) {
                    // ถูกยกเลิกหรือมีการเชื่อมต่อใหม่ระหว่างรอ
                    try {
                        s.close()
                    } catch (ignored: IOException) {
                        // ปิดไม่ได้ก็ข้าม
                    }
                    cancelled(result)
                    return
                }
                socket = s
                output = s.outputStream
                startReader(s)
                main.post { result.success(true) }
                return
            } catch (e: Exception) {
                pendingSockets.remove(token)
                lastError = e
                try {
                    s?.close()
                } catch (ignored: IOException) {
                    // ปิดไม่ได้ก็ข้าม
                }
            }
        }
        if (activeToken != token) {
            cancelled(result)
            return
        }
        val reason = lastError?.message ?: "ไม่ทราบสาเหตุ"
        main.post {
            result.error(
                "connect",
                "เชื่อมต่อตัวสแกนไม่สำเร็จ ตรวจว่าเสียบตัวสแกนและบิดกุญแจ ON แล้ว ถ้ามีหน้าต่างขอ PIN ให้ใส่ 1234 หรือ 0000 ($reason)",
                null,
            )
        }
    }

    private fun startReader(s: BluetoothSocket) {
        reading = true
        worker.execute {
            val buffer = ByteArray(1024)
            try {
                val input = s.inputStream
                while (reading) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    if (n > 0) {
                        val chunk = buffer.copyOf(n)
                        main.post { dataSink?.success(chunk) }
                    }
                }
            } catch (e: IOException) {
                // ช่องถูกปิด หรือตัวสแกนหลุด
            }
            if (reading && socket === s) {
                reading = false
                main.post { dataSink?.error("closed", "Bluetooth หลุดการเชื่อมต่อ", null) }
            }
        }
    }

    private fun closeSocket() {
        reading = false
        val s = socket
        socket = null
        output = null
        try {
            s?.close()
        } catch (e: IOException) {
            // ปิดไปแล้ว
        }
    }

    // ---------------- ค้นหาอุปกรณ์ Classic ----------------

    private fun startDiscovery() {
        withPermissions(bluetoothPermissions(true)) { ok ->
            val adapter = btAdapter
            // ฝั่งแอปเลิกค้นหาไปแล้วระหว่างรอผู้ใช้ตอบหน้าต่างขอสิทธิ์: ไม่ต้องเริ่มค้นหา
            val sink = scanSink ?: return@withPermissions
            if (!ok || adapter == null) {
                sink.error("permission", "ไม่ได้รับสิทธิ์ค้นหาอุปกรณ์ Bluetooth", null)
                return@withPermissions
            }
            if (discoveryReceiver == null) {
                val receiver = object : BroadcastReceiver() {
                    override fun onReceive(context: Context, intent: Intent) {
                        when (intent.action) {
                            BluetoothDevice.ACTION_FOUND -> {
                                val d = extraDevice(intent) ?: return
                                if (safeType(d) != BluetoothDevice.DEVICE_TYPE_LE) scanSink?.success(deviceMap(d))
                            }
                            BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> scanSink?.success(mapOf("done" to true))
                        }
                    }
                }
                val filter = IntentFilter().apply {
                    addAction(BluetoothDevice.ACTION_FOUND)
                    addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
                }
                if (Build.VERSION.SDK_INT >= 33) {
                    registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
                } else {
                    registerReceiver(receiver, filter)
                }
                discoveryReceiver = receiver
            }
            try {
                if (adapter.isDiscovering) adapter.cancelDiscovery()
                if (!adapter.startDiscovery()) sink.success(mapOf("done" to true))
            } catch (e: SecurityException) {
                sink.error("permission", "ไม่ได้รับสิทธิ์ค้นหาอุปกรณ์ Bluetooth", null)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun extraDevice(intent: Intent): BluetoothDevice? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        } else {
            intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
        }

    private fun stopDiscovery() {
        try {
            val adapter = btAdapter
            if (adapter != null && adapter.isDiscovering) adapter.cancelDiscovery()
        } catch (e: SecurityException) {
            // ไม่มีสิทธิ์ ข้าม
        }
        val receiver = discoveryReceiver
        discoveryReceiver = null
        if (receiver != null) {
            try {
                unregisterReceiver(receiver)
            } catch (e: IllegalArgumentException) {
                // ยกเลิกไปแล้ว
            }
        }
    }

    // ---------------- Wi-Fi ----------------

    /**
     * ตัวสแกน Wi-Fi ไม่มีอินเทอร์เน็ต Android จึงมักส่งข้อมูลออกทางเน็ตมือถือแทน
     * ผูกทั้งแอปไว้กับเครือข่าย Wi-Fi ระหว่างเชื่อมต่อ แล้วปลดเมื่อเลิกใช้
     */
    private fun onNet(call: MethodCall, result: MethodChannel.Result) {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        when (call.method) {
            "bindWifi" -> {
                if (cm == null) {
                    result.success(false)
                    return
                }
                @Suppress("DEPRECATION")
                val wifi = cm.allNetworks.firstOrNull { n ->
                    cm.getNetworkCapabilities(n)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                }
                result.success(wifi != null && cm.bindProcessToNetwork(wifi))
            }
            "unbind" -> {
                cm?.bindProcessToNetwork(null)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
