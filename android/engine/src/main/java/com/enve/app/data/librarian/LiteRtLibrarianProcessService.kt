package com.enve.app.data.librarian

import android.app.ActivityManager
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Messenger
import android.os.Process
import android.util.Log
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.InputData
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.SessionConfig
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class LiteRtLibrarianProcessService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val messenger = Messenger(IncomingHandler())
    private val engineMutex = Mutex()
    private var loadedModelPath: String? = null
    private var loadedCacheDir: String? = null
    private var loadedBackend: Backend? = null
    private var gpuFailed = false
    private var engine: Engine? = null

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onDestroy() {
        scope.cancel()
        engine?.close()
        engine = null
        loadedModelPath = null
        loadedCacheDir = null
        loadedBackend = null
        super.onDestroy()
    }

    private inner class IncomingHandler : Handler(Looper.getMainLooper()) {
        override fun handleMessage(msg: android.os.Message) {
            val messageType = msg.what
            if (messageType != LiteRtLibrarianProtocol.MSG_PREPARE &&
                messageType != LiteRtLibrarianProtocol.MSG_GENERATE
            ) {
                super.handleMessage(msg)
                return
            }
            val replyTo = msg.replyTo ?: return
            val data = msg.data
            val requestId = data.getString(LiteRtLibrarianProtocol.KEY_REQUEST_ID).orEmpty()
            val modelPath = data.getString(LiteRtLibrarianProtocol.KEY_MODEL_PATH).orEmpty()
            val cacheDir = data.getString(LiteRtLibrarianProtocol.KEY_CACHE_DIR).orEmpty()
            val prompt = data.getString(LiteRtLibrarianProtocol.KEY_PROMPT).orEmpty()
            val preferGpu = data.getBoolean(LiteRtLibrarianProtocol.KEY_PREFER_GPU, false)

            scope.launch {
                try {
                    val text = when (messageType) {
                        LiteRtLibrarianProtocol.MSG_PREPARE -> {
                            prepare(modelPath, cacheDir, preferGpu)
                            ""
                        }
                        LiteRtLibrarianProtocol.MSG_GENERATE -> generate(modelPath, cacheDir, prompt, preferGpu)
                        else -> error("Unsupported message type $messageType")
                    }
                    val what = if (messageType == LiteRtLibrarianProtocol.MSG_PREPARE) {
                        LiteRtLibrarianProtocol.MSG_READY
                    } else {
                        LiteRtLibrarianProtocol.MSG_RESPONSE
                    }
                    reply(replyTo, what, requestId, text)
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    reply(
                        replyTo = replyTo,
                        what = LiteRtLibrarianProtocol.MSG_ERROR,
                        requestId = requestId,
                        text = error.message ?: "Local Model failed.",
                    )
                }
            }
        }
    }

    private suspend fun prepare(modelPath: String, cacheDir: String, preferGpu: Boolean) {
        if (modelPath.isBlank()) throw EnveLibrarianException("Local Model request was incomplete.")
        engineMutex.withLock { prepareLocked(modelPath, cacheDir, preferGpu) }
    }

    private suspend fun generate(modelPath: String, cacheDir: String, prompt: String, preferGpu: Boolean): String {
        if (modelPath.isBlank() || prompt.isBlank()) throw EnveLibrarianException("Local Model request was incomplete.")
        engineMutex.withLock {
            prepareLocked(modelPath, cacheDir, preferGpu)
            val activeEngine = engine ?: throw EnveLibrarianException("Local Model failed to initialize.")
            val sessionConfig = SessionConfig(
                samplerConfig = SamplerConfig(topK = 24, topP = 0.82, temperature = 0.2, seed = 0),
            )
            activeEngine.createSession(sessionConfig).use { session ->
                Log.i(TAG, "Generating response for model prompt with ${prompt.length} chars")
                val text = session.generateContent(listOf(InputData.Text(prompt))).sanitizeLibrarianAnswer()
                Log.i(TAG, "Generation completed with ${text.length} chars")
                if (text.isBlank()) throw EnveLibrarianException("Local Model did not return an answer.")
                return text
            }
        }
    }

    private fun prepareLocked(modelPath: String, cacheDir: String, preferGpu: Boolean) {
        val backend = if (preferGpu && !gpuFailed) Backend.GPU else Backend.CPU
        if (loadedModelPath == modelPath &&
            loadedCacheDir == cacheDir &&
            loadedBackend == backend &&
            engine?.isInitialized() == true
        ) {
            return
        }

        engine?.close()
        engine = null
        loadedModelPath = null
        loadedCacheDir = null
        loadedBackend = null

        try {
            engine = try {
                initializeEngine(modelPath, cacheDir, backend).also { loadedBackend = backend }
            } catch (error: Throwable) {
                if (backend != Backend.GPU) throw error
                Log.w(TAG, "GPU backend failed to initialize, falling back to CPU", error)
                gpuFailed = true
                initializeEngine(modelPath, cacheDir, backend = Backend.CPU).also { loadedBackend = Backend.CPU }
            }
        } catch (error: Throwable) {

            File(cacheDir).listFiles()?.forEach { it.deleteRecursively() }
            throw error
        }
        loadedModelPath = modelPath
        loadedCacheDir = cacheDir
    }

    private fun initializeEngine(modelPath: String, cacheDir: String, backend: Backend): Engine {
        Log.i(TAG, "Initializing engine backend=$backend")
        val initializedEngine = Engine(
            EngineConfig(
                modelPath = modelPath,
                backend = backend,
                maxNumTokens = LITERT_MAX_NUM_TOKENS,
                cacheDir = cacheDir,
            )
        )
        try {
            initializedEngine.initialize()
        } catch (error: Throwable) {
            initializedEngine.close()
            throw error
        }
        return initializedEngine
    }

    private fun reply(replyTo: Messenger, what: Int, requestId: String, text: String) {
        val response = android.os.Message.obtain().apply {
            this.what = what
            data = Bundle().apply {
                putString(LiteRtLibrarianProtocol.KEY_REQUEST_ID, requestId)
                putString(LiteRtLibrarianProtocol.KEY_TEXT, text)
            }
        }
        runCatching { replyTo.send(response) }
    }
}

class LiteRtLibrarianProcessClient(
    private val context: Context,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val connectionMutex = Mutex()
    private var connection: BoundService? = null
    private var idleJob: Job? = null
    @Volatile private var gpuDisabled = false

    suspend fun generate(modelPath: String, cacheDir: String, prompt: String): String =
        withContext(Dispatchers.Main.immediate) {
            idleJob?.cancel()
            val preferGpu = !gpuDisabled
            val service = acquireConnection()
            try {
                try {
                    withTimeout(LITERT_MODEL_LOAD_TIMEOUT_MS) {
                        Log.i(TAG, "Preparing local model preferGpu=$preferGpu")
                        service.prepare(modelPath, cacheDir, preferGpu)
                        Log.i(TAG, "Local model ready")
                    }
                } catch (e: TimeoutCancellationException) {
                    Log.w(TAG, "Local model load timed out (preferGpu=$preferGpu)", e)

                    if (preferGpu) gpuDisabled = true
                    dropConnection(kill = true)
                    throw EnveLibrarianException("Local Model took too long to load on this device. Please try again.")
                }
                try {
                    withTimeout(LITERT_GENERATE_TIMEOUT_MS) {
                        Log.i(TAG, "Running local model generation")
                        service.generate(modelPath, cacheDir, prompt, preferGpu)
                    }
                } catch (e: TimeoutCancellationException) {

                    Log.w(TAG, "Local model generation timed out", e)
                    throw EnveLibrarianException("Local Model took too long to answer. Please try again with a shorter question.")
                }
            } finally {
                scheduleIdleDisconnect()
            }
        }

    private suspend fun acquireConnection(): BoundService = connectionMutex.withLock {
        connection?.takeIf { it.isAlive }?.let { return it }
        connection?.close()
        connection = null
        val bound = withTimeout(LITERT_BIND_TIMEOUT_MS) { bindService() }
        connection = bound
        bound
    }

    private fun scheduleIdleDisconnect() {
        idleJob?.cancel()
        idleJob = scope.launch {
            delay(LITERT_IDLE_UNLOAD_MS)
            dropConnection(kill = false)
        }
    }

    private suspend fun dropConnection(kill: Boolean) {
        connectionMutex.withLock {
            connection?.close()
            connection = null
        }
        if (kill) killModelProcess()
    }

    private suspend fun bindService(): BoundService =
        suspendCancellableCoroutine { continuation ->
            val finished = AtomicBoolean(false)
            var needsUnbind = false

            fun cleanup(serviceConnection: ServiceConnection) {
                if (needsUnbind) {
                    runCatching { context.unbindService(serviceConnection) }
                    needsUnbind = false
                }
            }

            lateinit var serviceConnection: ServiceConnection
            fun fail(error: Throwable) {
                if (finished.compareAndSet(false, true)) {
                    cleanup(serviceConnection)
                    continuation.resumeWithException(error)
                }
            }

            var boundService: BoundService? = null
            serviceConnection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName, service: IBinder) {
                    if (finished.get()) {
                        cleanup(this)
                        return
                    }
                    val bound = BoundService(
                        binder = service,
                        closeBlock = { cleanup(this) },
                    )
                    boundService = bound
                    if (finished.compareAndSet(false, true)) {
                        continuation.resume(bound) { _, value, _ ->
                            value.close()
                        }
                    }
                }

                override fun onServiceDisconnected(name: ComponentName) {
                    boundService?.onProcessDied()
                        ?: fail(EnveLibrarianException("Local Model process stopped."))
                }

                override fun onBindingDied(name: ComponentName) {
                    boundService?.onProcessDied()
                        ?: fail(EnveLibrarianException("Local Model process stopped."))
                }

                override fun onNullBinding(name: ComponentName) {
                    fail(EnveLibrarianException("Local Model process is unavailable."))
                }
            }

            continuation.invokeOnCancellation {
                if (finished.compareAndSet(false, true)) {
                    cleanup(serviceConnection)
                }
            }

            val intent = Intent(context, LiteRtLibrarianProcessService::class.java)
            val didBind = context.bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
            if (!didBind) {
                fail(EnveLibrarianException("Local Model process is unavailable."))
            } else {
                needsUnbind = true
            }
        }

    private fun killModelProcess() {
        Log.i(TAG, "Stopping local model process")
        val processName = "${context.packageName}:${LiteRtLibrarianProtocol.PROCESS_SUFFIX}"
        val activityManager = context.getSystemService(ActivityManager::class.java) ?: return
        activityManager.runningAppProcesses
            ?.firstOrNull { it.processName == processName }
            ?.pid
            ?.let { pid ->
                Log.i(TAG, "Killing local model pid=$pid")
                Process.killProcess(pid)
            }
    }

    private class BoundService(
        binder: IBinder,
        private val closeBlock: () -> Unit,
    ) {
        private val messenger = Messenger(binder)
        private val alive = AtomicBoolean(true)
        private val pending = ConcurrentHashMap<String, (Result<String>) -> Unit>()
        private val deathRecipient = IBinder.DeathRecipient { onProcessDied() }

        init {
            runCatching { binder.linkToDeath(deathRecipient, 0) }
                .onFailure { onProcessDied() }
        }

        val isAlive: Boolean get() = alive.get()

        fun onProcessDied() {
            if (!alive.compareAndSet(true, false)) return
            Log.w(TAG, "Local model process died with ${pending.size} in-flight request(s)")
            val callbacks = pending.values.toList()
            pending.clear()
            callbacks.forEach { callback ->
                callback(
                    Result.failure(
                        EnveLibrarianException("Local Model ran out of memory on this device. Please try again.")
                    )
                )
            }
        }

        suspend fun prepare(modelPath: String, cacheDir: String, preferGpu: Boolean) {
            request(
                what = LiteRtLibrarianProtocol.MSG_PREPARE,
                modelPath = modelPath,
                cacheDir = cacheDir,
                prompt = "",
                preferGpu = preferGpu,
                successWhat = LiteRtLibrarianProtocol.MSG_READY,
            )
        }

        suspend fun generate(modelPath: String, cacheDir: String, prompt: String, preferGpu: Boolean): String =
            request(
                what = LiteRtLibrarianProtocol.MSG_GENERATE,
                modelPath = modelPath,
                cacheDir = cacheDir,
                prompt = prompt,
                preferGpu = preferGpu,
                successWhat = LiteRtLibrarianProtocol.MSG_RESPONSE,
            )

        fun close() {
            alive.set(false)
            closeBlock()
        }

        private suspend fun request(
            what: Int,
            modelPath: String,
            cacheDir: String,
            prompt: String,
            preferGpu: Boolean,
            successWhat: Int,
        ): String = suspendCancellableCoroutine { continuation ->
            if (!alive.get()) {
                continuation.resumeWithException(EnveLibrarianException("Local Model process stopped."))
                return@suspendCancellableCoroutine
            }
            val requestId = UUID.randomUUID().toString()
            val finished = AtomicBoolean(false)
            Log.i(
                TAG,
                "Sending local model request what=$what requestId=$requestId promptChars=${prompt.length}"
            )

            fun complete(result: Result<String>) {
                pending.remove(requestId)
                if (finished.compareAndSet(false, true)) {
                    result.fold(continuation::resume, continuation::resumeWithException)
                }
            }
            pending[requestId] = ::complete

            val replyMessenger = Messenger(Handler(Looper.getMainLooper()) { response ->
                if (response.data.getString(LiteRtLibrarianProtocol.KEY_REQUEST_ID) != requestId) {
                    return@Handler true
                }
                val text = response.data.getString(LiteRtLibrarianProtocol.KEY_TEXT).orEmpty()
                Log.i(
                    TAG,
                    "Received local model reply what=${response.what} requestId=$requestId textChars=${text.length}"
                )
                if (response.what == successWhat) {
                    complete(Result.success(text))
                } else {
                    complete(Result.failure(EnveLibrarianException(text.ifBlank { "Local Model failed." })))
                }
                true
            })

            val request = android.os.Message.obtain().apply {
                this.what = what
                replyTo = replyMessenger
                data = Bundle().apply {
                    putString(LiteRtLibrarianProtocol.KEY_REQUEST_ID, requestId)
                    putString(LiteRtLibrarianProtocol.KEY_MODEL_PATH, modelPath)
                    putString(LiteRtLibrarianProtocol.KEY_CACHE_DIR, cacheDir)
                    putString(LiteRtLibrarianProtocol.KEY_PROMPT, prompt)
                    putBoolean(LiteRtLibrarianProtocol.KEY_PREFER_GPU, preferGpu)
                }
            }

            runCatching { messenger.send(request) }
                .onFailure { complete(Result.failure(it)) }

            continuation.invokeOnCancellation {
                pending.remove(requestId)
                finished.set(true)
            }
        }
    }
}

private object LiteRtLibrarianProtocol {
    const val PROCESS_SUFFIX = "librarian_model"
    const val MSG_PREPARE = 1
    const val MSG_READY = 2
    const val MSG_GENERATE = 3
    const val MSG_RESPONSE = 4
    const val MSG_ERROR = 5
    const val KEY_REQUEST_ID = "requestId"
    const val KEY_MODEL_PATH = "modelPath"
    const val KEY_CACHE_DIR = "cacheDir"
    const val KEY_PROMPT = "prompt"
    const val KEY_PREFER_GPU = "preferGpu"
    const val KEY_TEXT = "text"
}

internal const val LITERT_BIND_TIMEOUT_MS = 10_000L
internal const val LITERT_MODEL_LOAD_TIMEOUT_MS = 300_000L
internal const val LITERT_GENERATE_TIMEOUT_MS = 240_000L
const val LITERT_GENERATE_TIMEOUT_HINT_MINUTES = 5
private const val LITERT_IDLE_UNLOAD_MS = 300_000L
private const val LITERT_MAX_NUM_TOKENS = 2048
private const val TAG = "LiteRtLibrarian"
