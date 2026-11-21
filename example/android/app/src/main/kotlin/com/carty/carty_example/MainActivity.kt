package com.carty.carty_example

import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.opengl.EGL14
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Config
import com.google.ar.core.Plane
import com.google.ar.core.RecordingConfig
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import com.google.ar.core.exceptions.NotYetAvailableException
import android.media.Image
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/// On-device spike scaffolding.
///
/// Channels:
///   carty/arcore_spike — ARCore availability probing and the live 6-DoF pose
///     probe (EGL pbuffer + real ARCore Session). Degrades honestly without AR.
///   carty/video_frames — Android platform-decoder frame source for the
///     third-class pre-recorded-video input (MediaMetadataRetriever over
///     MethodChannel; ffmpeg is absent on Android).
class MainActivity : FlutterActivity() {
    private companion object {
        const val ARCORE_CHANNEL = "carty/arcore_spike"
        const val VIDEO_CHANNEL = "carty/video_frames"
        const val CAPTURE_CHANNEL = "carty/capture"
        const val CAPTURE_KEYFRAME_CHANNEL = "carty/capture_keyframes"
        const val CAMERA_PERMISSION_CODE = 1001
        // Hard cap on a single capture's keyframes so the sidecar/loop stay
        // bounded regardless of how long Record is held (Tiger Style).
        const val CAPTURE_MAX_KEYFRAMES = 20_000
        // Downscaled width streamed to the live fusion loop. Small keeps the
        // per-pixel back-projection (accreteFromFrame) + the platform-channel
        // copy cheap; intrinsics are scaled to match (see emitKeyframe).
        const val LIVE_STREAM_WIDTH = 160
        // Stream every Nth TRACKING keyframe to the live loop (~ARCore 30 fps / N).
        // The sidecar still records EVERY frame; this only throttles the live feed.
        const val LIVE_STREAM_STRIDE = 2
        // ARCore anchors world Y=0 at the camera START pose, NOT the floor, but the
        // splat (carty_fusion.cpp) intersects rays with world Y=0 assuming it IS the
        // floor. We locate the floor (lowest tracked horizontal-upward plane) and
        // express pose heights above it. If no plane is found within the grace
        // window, fall back to a typical hand-held height so the demo still maps.
        const val FLOOR_GRACE_FRAMES = 120
        const val DEFAULT_FLOOR_DROP_M = 1.2f
    }

    // Single-thread executor: blocking work (video decode, ARCore Session) never
    // runs on the main thread.
    private val bgExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    // Held across the camera-permission callback so we can resume the probe.
    private var pendingPoseResult: MethodChannel.Result? = null
    private var pendingMaxFrames: Int = 30

    // --- Live capture state (carty/capture) ---
    // The capture loop runs on bgExecutor and polls [captureStop] each frame;
    // Dart's "Stop" flips it and the loop finalizes the files. The result map is
    // delivered to the stopCapture call (or to startCapture if it crashes first).
    private val captureRunning = AtomicBoolean(false)
    private val captureStop = AtomicBoolean(false)
    private var captureResult: Map<String, Any>? = null
    private var captureError: String? = null

    // Live keyframe push sink (carty/capture_keyframes). Set when Dart subscribes,
    // cleared on cancel; read only on the main thread. Volatile so the capture
    // loop (bgExecutor) sees the latest value when it posts an emit.
    @Volatile
    private var keyframeSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ARCORE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // Returns the ArCoreApk.Availability enum name.
                "availability" -> {
                    try {
                        result.success(
                            ArCoreApk.getInstance().checkAvailability(this).name,
                        )
                    } catch (e: Exception) {
                        result.error("ARCORE_UNAVAILABLE", e.message, null)
                    }
                }
                // Kicks off Play-Services-for-AR install/update.
                "requestInstall" -> {
                    try {
                        result.success(
                            ArCoreApk.getInstance()
                                .requestInstall(this, true)
                                .name,
                        )
                    } catch (e: Exception) {
                        result.error("ARCORE_INSTALL_FAILED", e.message, null)
                    }
                }
                // Collects up to maxFrames ARCore Session updates and returns a list
                // of {trackingState, tx/ty/tz, qx/qy/qz/qw, floorPlaneTracked,
                // floorY} maps. Requires CAMERA permission; requests it if absent.
                "startPoseProbe" -> {
                    val maxFrames = call.argument<Int>("maxFrames") ?: 30
                    val hasCam = ContextCompat.checkSelfPermission(
                        this, android.Manifest.permission.CAMERA,
                    ) == PackageManager.PERMISSION_GRANTED
                    if (!hasCam) {
                        pendingPoseResult = result
                        pendingMaxFrames = maxFrames
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(android.Manifest.permission.CAMERA),
                            CAMERA_PERMISSION_CODE,
                        )
                    } else {
                        runOnBg({ runPoseProbe(maxFrames) }, result)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VIDEO_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "probe" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("BAD_ARGS", "path missing", null)
                    } else {
                        runOnBg({ probe(path) }, result)
                    }
                }
                "frameAt" -> {
                    val path = call.argument<String>("path")
                    val timeUs = call.argument<Number>("timeUs")?.toLong()
                    val targetWidth = call.argument<Int>("targetWidth")
                    val targetHeight = call.argument<Int>("targetHeight")
                    if (path.isNullOrEmpty() || timeUs == null ||
                        targetWidth == null || targetHeight == null
                    ) {
                        result.error("BAD_ARGS", "frameAt args missing", null)
                    } else {
                        runOnBg(
                            { frameAt(path, timeUs, targetWidth, targetHeight) },
                            result,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }

        // carty/capture — the live recorder behind CapturePage's CaptureController
        // seam. startCapture spins up an ARCore Session that records video.mp4 +
        // writes sidecar.ndjson (one PoseSample line per TRACKING keyframe);
        // stopCapture signals the loop to finalize and returns the paths + count.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CAPTURE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startCapture" -> startCapture(result)
                "stopCapture" -> stopCapture(result)
                else -> result.notImplemented()
            }
        }

        // carty/capture_keyframes — the live per-keyframe push stream.
        // The capture loop emits {image, width, height, channels, fx/fy/cx/cy,
        // t/tx..qw, state} per keyframe; the Dart LiveFusionController folds each
        // via accreteFromFrame. onListen/onCancel just track the sink.
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CAPTURE_KEYFRAME_CHANNEL,
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                keyframeSink = events
            }

            override fun onCancel(arguments: Any?) {
                keyframeSink = null
            }
        })
    }

    /// Begins a live capture: requests CAMERA if needed, then runs the recording
    /// loop on the background executor. Returns immediately (success) once the
    /// loop is launched — the actual files are returned by [stopCapture].
    private fun startCapture(result: MethodChannel.Result) {
        if (captureRunning.get()) {
            result.error("CAPTURE_BUSY", "a capture is already running", null)
            return
        }
        val hasCam = ContextCompat.checkSelfPermission(
            this, android.Manifest.permission.CAMERA,
        ) == PackageManager.PERMISSION_GRANTED
        if (!hasCam) {
            result.error(
                "NO_CAMERA_PERMISSION",
                "CAMERA permission denied — grant it (open the ARCore spike once) and retry.",
                null,
            )
            return
        }
        captureStop.set(false)
        captureError = null
        captureResult = null
        captureRunning.set(true)
        bgExecutor.execute {
            try {
                captureResult = runCapture()
            } catch (e: Exception) {
                captureError = e.message ?: e.toString()
            } finally {
                captureRunning.set(false)
            }
        }
        result.success(null)
    }

    /// Signals the running capture loop to finalize, waits (bounded) for it to
    /// flush video.mp4 + sidecar.ndjson, then returns {videoPath, sidecarPath,
    /// frameCount}. Crashing the boundary on a never-started capture would hide a
    /// caller bug, so we report it as a recoverable channel error instead.
    private fun stopCapture(result: MethodChannel.Result) {
        captureStop.set(true)
        bgExecutor.execute {
            // bgExecutor is single-threaded: this runnable cannot start until the
            // capture loop (also on bgExecutor) has returned, so the result is
            // ready here with no busy-wait.
            val err = captureError
            val res = captureResult
            mainHandler.post {
                when {
                    err != null -> result.error("CAPTURE_ERROR", err, null)
                    res != null -> result.success(res)
                    else -> result.error(
                        "CAPTURE_NOT_RUN",
                        "stopCapture before any capture produced a result",
                        null,
                    )
                }
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CAMERA_PERMISSION_CODE) {
            val pending = pendingPoseResult ?: return
            pendingPoseResult = null
            val maxFrames = pendingMaxFrames
            if (grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            ) {
                runOnBg({ runPoseProbe(maxFrames) }, pending)
            } else {
                pending.error(
                    "NO_CAMERA_PERMISSION",
                    "CAMERA permission denied — grant it in system settings and retry.",
                    null,
                )
            }
        }
    }

    /// Runs [work] on the background executor; delivers result/error on the main
    /// thread (MethodChannel.Result must be called from the main thread).
    private fun runOnBg(work: () -> Any?, result: MethodChannel.Result) {
        bgExecutor.execute {
            try {
                val value = work()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("BG_ERROR", e.message ?: e.toString(), null)
                }
            }
        }
    }

    /// Opens a headless EGL pbuffer context, creates a GL texture for ARCore's
    /// camera feed, runs up to [maxFrames] Session.update() calls, and returns
    /// a bounded list of pose + plane snapshots.
    ///
    /// Tiger Style: bounded by [maxFrames] (no unbounded loop); EGL torn down in
    /// a finally block so no context leaks. The pbuffer approach is the standard
    /// pattern for headless ARCore operation — no visible surface needed.
    private fun runPoseProbe(maxFrames: Int): List<Map<String, Any>> {
        // --- Headless EGL context ---
        val eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(eglDisplay != EGL14.EGL_NO_DISPLAY) { "EGL: no display" }
        val major = IntArray(1); val minor = IntArray(1)
        check(EGL14.eglInitialize(eglDisplay, major, 0, minor, 0)) {
            "EGL: init failed (${EGL14.eglGetError()})"
        }

        val configAttribs = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<android.opengl.EGLConfig>(1)
        val numConfigs = IntArray(1)
        check(
            EGL14.eglChooseConfig(
                eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0,
            ),
        ) { "EGL: eglChooseConfig failed (${EGL14.eglGetError()})" }
        check(numConfigs[0] > 0) { "EGL: no matching EGL config" }

        val pbAttribs = intArrayOf(
            EGL14.EGL_WIDTH, 16, EGL14.EGL_HEIGHT, 16, EGL14.EGL_NONE,
        )
        val eglSurface = EGL14.eglCreatePbufferSurface(
            eglDisplay, configs[0], pbAttribs, 0,
        )
        check(eglSurface != EGL14.EGL_NO_SURFACE) {
            "EGL: no pbuffer surface (${EGL14.eglGetError()})"
        }

        val ctxAttribs = intArrayOf(
            EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE,
        )
        val eglContext = EGL14.eglCreateContext(
            eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, ctxAttribs, 0,
        )
        check(eglContext != EGL14.EGL_NO_CONTEXT) {
            "EGL: no context (${EGL14.eglGetError()})"
        }
        check(
            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext),
        ) { "EGL: eglMakeCurrent failed (${EGL14.eglGetError()})" }

        // ARCore requires an OES external texture for the camera feed —
        // a regular GL_TEXTURE_2D cannot receive the SurfaceTexture data.
        val texIds = IntArray(1)
        GLES20.glGenTextures(1, texIds, 0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texIds[0])
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE,
        )

        // --- ARCore Session ---
        val session = Session(this)
        try {
            val config = Config(session).apply {
                updateMode = Config.UpdateMode.BLOCKING
                planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
            }
            session.configure(config)
            session.setCameraTextureName(texIds[0])
            session.resume()

            val snapshots = ArrayList<Map<String, Any>>(maxFrames)
            repeat(maxFrames) {
                val frame = session.update()
                val cam = frame.camera
                val p = cam.displayOrientedPose
                val planes = session.getAllTrackables(Plane::class.java)
                val floor = planes.firstOrNull {
                    it.type == Plane.Type.HORIZONTAL_UPWARD_FACING &&
                        it.trackingState == TrackingState.TRACKING
                }
                snapshots.add(
                    mapOf(
                        "trackingState" to cam.trackingState.name,
                        "tx" to p.tx().toDouble(),
                        "ty" to p.ty().toDouble(),
                        "tz" to p.tz().toDouble(),
                        "qx" to p.qx().toDouble(),
                        "qy" to p.qy().toDouble(),
                        "qz" to p.qz().toDouble(),
                        "qw" to p.qw().toDouble(),
                        "floorPlaneTracked" to (floor != null),
                        "floorY" to (floor?.centerPose?.ty()?.toDouble() ?: 0.0),
                    ),
                )
            }
            session.pause()
            return snapshots
        } finally {
            session.close()
            EGL14.eglMakeCurrent(
                eglDisplay,
                EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_CONTEXT,
            )
            EGL14.eglDestroyContext(eglDisplay, eglContext)
            EGL14.eglDestroySurface(eglDisplay, eglSurface)
            EGL14.eglTerminate(eglDisplay)
        }
    }

    /// Runs ONE live capture: an ARCore Session over a headless EGL pbuffer that
    /// records video.mp4 (Session.startRecording, ARCore 1.24+) and writes
    /// sidecar.ndjson — one PoseSample JSON line per TRACKING keyframe in the
    /// frozen pose-sidecar schema, so the Dart ReplayHarness replays it deterministically.
    /// Loops until Dart flips [captureStop]; bounded by [CAPTURE_MAX_KEYFRAMES]
    /// so the files can never grow without limit (Tiger Style). EGL/Session/
    /// writer are all torn down in finally so nothing leaks on any exit path.
    private fun runCapture(): Map<String, Any> {
        val outDir = File(cacheDir, "capture").apply { mkdirs() }
        val stamp = System.currentTimeMillis()
        val videoFile = File(outDir, "video_$stamp.mp4")
        val sidecarFile = File(outDir, "sidecar_$stamp.ndjson")

        // --- Headless EGL context (mirrors runPoseProbe) ---
        val eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(eglDisplay != EGL14.EGL_NO_DISPLAY) { "EGL: no display" }
        val major = IntArray(1); val minor = IntArray(1)
        check(EGL14.eglInitialize(eglDisplay, major, 0, minor, 0)) {
            "EGL: init failed (${EGL14.eglGetError()})"
        }
        val configAttribs = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<android.opengl.EGLConfig>(1)
        val numConfigs = IntArray(1)
        check(
            EGL14.eglChooseConfig(
                eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0,
            ),
        ) { "EGL: eglChooseConfig failed (${EGL14.eglGetError()})" }
        check(numConfigs[0] > 0) { "EGL: no matching EGL config" }
        val pbAttribs = intArrayOf(
            EGL14.EGL_WIDTH, 16, EGL14.EGL_HEIGHT, 16, EGL14.EGL_NONE,
        )
        val eglSurface = EGL14.eglCreatePbufferSurface(
            eglDisplay, configs[0], pbAttribs, 0,
        )
        check(eglSurface != EGL14.EGL_NO_SURFACE) {
            "EGL: no pbuffer surface (${EGL14.eglGetError()})"
        }
        val ctxAttribs = intArrayOf(
            EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE,
        )
        val eglContext = EGL14.eglCreateContext(
            eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, ctxAttribs, 0,
        )
        check(eglContext != EGL14.EGL_NO_CONTEXT) {
            "EGL: no context (${EGL14.eglGetError()})"
        }
        check(
            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext),
        ) { "EGL: eglMakeCurrent failed (${EGL14.eglGetError()})" }

        // ARCore requires an OES external texture for the camera feed — a plain
        // GL_TEXTURE_2D leaves the feed dark and every frame PAUSED.
        val texIds = IntArray(1)
        GLES20.glGenTextures(1, texIds, 0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texIds[0])
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE,
        )

        val session = Session(this)
        val writer = sidecarFile.bufferedWriter()
        var frameCount = 0
        // Floor reference (see FLOOR_GRACE_FRAMES): the lowest tracked horizontal
        // plane's world Y. Cached across frames so a momentary loss of the plane
        // does not unanchor the map; firstCamY seeds the fallback height.
        var floorY: Float? = null
        var firstCamY: Float? = null
        var trackingFrames = 0
        try {
            val config = Config(session).apply {
                updateMode = Config.UpdateMode.BLOCKING
                planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
                // RAW depth (not full/inpainted) so depth recording records honest geometry with
                // a confidence plane; guarded so a depth-less device still captures
                // pose-only (the depth block is optional by schema).
                if (session.isDepthModeSupported(Config.DepthMode.RAW_DEPTH_ONLY)) {
                    depthMode = Config.DepthMode.RAW_DEPTH_ONLY
                }
            }
            session.configure(config)
            session.setCameraTextureName(texIds[0])

            // MP4 recording embedded by ARCore (simpler than a separate
            // MediaRecorder): the recorded session is itself replayable.
            val recordingConfig = RecordingConfig(session)
                .setMp4DatasetUri(android.net.Uri.fromFile(videoFile))
                .setAutoStopOnPause(false)
            session.startRecording(recordingConfig)
            session.resume()

            // Loop until Dart stops us, bounded by the keyframe cap.
            while (!captureStop.get() && frameCount < CAPTURE_MAX_KEYFRAMES) {
                val frame = session.update()
                val cam = frame.camera
                val ts = cam.trackingState
                val tracking = ts == TrackingState.TRACKING
                // Record EVERY keyframe's state (TRACKING or PAUSED) so replay can
                // show the gap honestly; only TRACKING carries a trustworthy pose.
                val p = cam.displayOrientedPose
                val stateName = if (tracking) "TRACKING" else "PAUSED"
                // ARCore frame timestamp (ns → ms) is monotonic and unique per
                // frame, so it is a stable keyframe_id for accrete idempotency
                // (System.currentTimeMillis can collide within a millisecond).
                val tMs = frame.timestamp / 1_000_000L

                // Locate / refresh the floor on every TRACKING frame. Take the
                // LOWEST horizontal-upward plane (a table/bed sits above the floor).
                if (tracking) {
                    trackingFrames++
                    if (firstCamY == null) firstCamY = cam.pose.ty()
                    val planes = session.getAllTrackables(Plane::class.java)
                    for (pl in planes) {
                        if (pl.type == Plane.Type.HORIZONTAL_UPWARD_FACING &&
                            pl.trackingState == TrackingState.TRACKING
                        ) {
                            val y = pl.centerPose.ty()
                            if (floorY == null || y < floorY!!) floorY = y
                        }
                    }
                }
                // Floor world-Y to subtract so the splat's "Y=0 == floor" holds.
                // Null until either a plane is found or the grace window elapses.
                val effFloorY = floorY
                    ?: if (trackingFrames > FLOOR_GRACE_FRAMES && firstCamY != null)
                        firstCamY!! - DEFAULT_FLOOR_DROP_M
                    else null

                // Record raw depth only on TRACKING frames (acquireRawDepthImage
                // throws NotTrackingException otherwise) so depth reprojection can reproject offline.
                val depthFrag = if (tracking) {
                    depthBlock(frame, cam, outDir, tMs, effFloorY ?: 0f)
                } else {
                    ""
                }
                writer.write(poseLine(tMs, p, stateName, effFloorY ?: 0f, depthFrag))
                writer.write("\n")

                // Live push to the fusion loop: only TRACKING keyframes with a
                // known floor carry a usable pose; we throttle by stride so the
                // per-pixel back-projection (accreteFromFrame) stays real-time. The
                // sidecar above still records EVERY frame — this only thins it.
                val sink = keyframeSink
                if (sink != null && tracking && effFloorY != null &&
                    frameCount % LIVE_STREAM_STRIDE == 0
                ) {
                    emitKeyframe(sink, frame, cam, tMs, effFloorY)
                }
                frameCount++
            }
            writer.flush()
            session.pause()
            session.stopRecording()
            return mapOf(
                "videoPath" to videoFile.absolutePath,
                "sidecarPath" to sidecarFile.absolutePath,
                "frameCount" to frameCount,
            )
        } finally {
            try { writer.close() } catch (_: Exception) {}
            session.close()
            EGL14.eglMakeCurrent(
                eglDisplay,
                EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_CONTEXT,
            )
            EGL14.eglDestroyContext(eglDisplay, eglContext)
            EGL14.eglDestroySurface(eglDisplay, eglSurface)
            EGL14.eglTerminate(eglDisplay)
        }
    }

    /// One pose-sidecar line in the FROZEN pose-sidecar schema
    /// {"t","tx","ty","tz","qx","qy","qz","qw","state"}. Hand-built (no JSON lib
    /// dependency) but field-for-field exact so PoseSample.fromJsonLine parses it;
    /// numeric only (no string escaping needed) — state is a fixed enum literal.
    /// [floorY] is subtracted from the height so the recorded ty is metres ABOVE
    /// the floor (Y=0 == floor) — the invariant the splat assumes (carty_fusion).
    private fun poseLine(
        t: Long,
        p: com.google.ar.core.Pose,
        state: String,
        floorY: Float,
        depthFragment: String,
    ): String {
        // [depthFragment] is the optional depth block (",\"depth\":..."), spliced
        // INSIDE the object before the closing brace; "" for a depth-less line keeps
        // the line byte-identical to the pre-depth schema.
        return "{\"t\":$t," +
            "\"tx\":${p.tx()},\"ty\":${p.ty() - floorY},\"tz\":${p.tz()}," +
            "\"qx\":${p.qx()},\"qy\":${p.qy()},\"qz\":${p.qz()},\"qw\":${p.qw()}," +
            "\"state\":\"$state\"$depthFragment}"
    }

    /// Writes the raw depth + confidence blobs for keyframe [t] and returns the
    /// sidecar-line fragment (depth block) to append, or "" when depth is not yet
    /// available. RAW (not full) depth: full depth is inpainted (fabricated
    /// geometry) and carries no confidence. Sensor-native bytes are saved verbatim
    /// — never pre-rotated — and paired with cam.pose (the PHYSICAL sensor pose),
    /// because the depth buffer + getImageIntrinsics live in the sensor frame while
    /// the pose line's tx..qw is displayOrientedPose. Images are closed immediately
    /// so ARCore's small image pool never starves and freezes tracking.
    private fun depthBlock(
        frame: com.google.ar.core.Frame,
        cam: com.google.ar.core.Camera,
        outDir: File,
        t: Long,
        floorY: Float,
    ): String {
        val depthImg = try {
            frame.acquireRawDepthImage16Bits()
        } catch (e: NotYetAvailableException) {
            return ""
        }
        var confImg: android.media.Image? = null
        try {
            confImg = try {
                frame.acquireRawDepthConfidenceImage()
            } catch (e: NotYetAvailableException) {
                null
            }
            val dw = depthImg.width
            val dh = depthImg.height
            check(dw > 0 && dh > 0) { "raw depth image has empty dimensions" }

            // DEPTH16: one 16-bit plane, little-endian mm, row-major. Copy verbatim
            // (no 0x1FFF mask — that is the deprecated acquireDepthImage path only).
            val dBuf = depthImg.planes[0].buffer // ByteBuffer, little-endian
            val depthBytes = ByteArray(dBuf.remaining())
            dBuf.get(depthBytes)
            File(outDir, "d_$t.dep").writeBytes(depthBytes)

            var confName: String? = null
            if (confImg != null) {
                val cBuf = confImg.planes[0].buffer
                val confBytes = ByteArray(cBuf.remaining())
                cBuf.get(confBytes)
                File(outDir, "c_$t.dep").writeBytes(confBytes)
                confName = "c_$t.dep"
            }

            // Depth-camera intrinsics: getImageIntrinsics is the CPU-image family
            // (unrotated, uncropped) the depth buffer belongs to. Scale to dw×dh.
            val intr = cam.imageIntrinsics
            val dims = intr.imageDimensions // {width, height} of the CPU image
            val fl = intr.focalLength       // {fx, fy}
            val pp = intr.principalPoint    // {cx, cy}
            val sx = dw.toDouble() / dims[0].toDouble()
            val sy = dh.toDouble() / dims[1].toDouble()

            // Physical-sensor pose (NOT displayOrientedPose); ty floor-relative so
            // Y=0 == floor, matching the pose line's convention.
            val sp = cam.pose

            val sb = StringBuilder(220)
            sb.append(",\"depth\":\"d_").append(t).append(".dep\"")
            if (confName != null) sb.append(",\"conf\":\"").append(confName).append("\"")
            sb.append(",\"dw\":").append(dw).append(",\"dh\":").append(dh)
            sb.append(",\"fx\":").append(fl[0] * sx).append(",\"fy\":").append(fl[1] * sy)
            sb.append(",\"cx\":").append(pp[0] * sx).append(",\"cy\":").append(pp[1] * sy)
            sb.append(",\"stx\":").append(sp.tx())
            sb.append(",\"sty\":").append(sp.ty() - floorY)
            sb.append(",\"stz\":").append(sp.tz())
            sb.append(",\"sqx\":").append(sp.qx()).append(",\"sqy\":").append(sp.qy())
            sb.append(",\"sqz\":").append(sp.qz()).append(",\"sqw\":").append(sp.qw())
            return sb.toString()
        } finally {
            depthImg.close()
            confImg?.close()
        }
    }

    /// Pushes ONE live keyframe to the fusion loop: the sensor camera image
    /// (downscaled), its scaled pinhole intrinsics, and the PHYSICAL camera pose.
    /// The three MUST come from the same frame in the same (sensor) frame of
    /// reference — cam.pose + cam.imageIntrinsics + acquireCameraImage() are
    /// mutually consistent; mixing in displayOrientedPose (used by the sidecar for
    /// human-upright replay) would rotate the splat against the image and smear
    /// the map. Bounded: one bitmap-free YUV→RGBA pass at LIVE_STREAM_WIDTH.
    /// NotYetAvailableException early in a session is normal — skip that frame.
    private fun emitKeyframe(
        sink: EventChannel.EventSink,
        frame: com.google.ar.core.Frame,
        cam: com.google.ar.core.Camera,
        tMs: Long,
        floorY: Float,
    ) {
        val image = try {
            frame.acquireCameraImage()
        } catch (e: NotYetAvailableException) {
            return
        }
        try {
            val srcW = image.width
            val srcH = image.height
            check(srcW > 0 && srcH > 0) { "camera image has empty dimensions" }
            val dstW = LIVE_STREAM_WIDTH
            // Preserve aspect so the scaled intrinsics stay isotropic (one scale).
            val dstH = (LIVE_STREAM_WIDTH.toLong() * srcH / srcW).toInt()
            check(dstH > 0) { "downscaled height collapsed to zero" }
            val rgba = yuvToRgba(image, dstW, dstH)

            // imageIntrinsics describe the SENSOR image (matches acquireCameraImage),
            // in full-resolution pixels — scale them to the downscaled feed.
            val intr = cam.imageIntrinsics
            val fl = intr.focalLength      // [fx, fy]
            val pp = intr.principalPoint   // [cx, cy]
            val scale = dstW.toDouble() / srcW.toDouble()

            val pose = cam.pose
            val payload = HashMap<String, Any>(20)
            payload["t"] = tMs
            payload["tx"] = pose.tx().toDouble()
            // Height ABOVE the floor (Y=0 == floor) — the splat's ground-plane
            // invariant; without this the rays collapse at the camera origin.
            payload["ty"] = (pose.ty() - floorY).toDouble()
            payload["tz"] = pose.tz().toDouble()
            payload["qx"] = pose.qx().toDouble()
            payload["qy"] = pose.qy().toDouble()
            payload["qz"] = pose.qz().toDouble()
            payload["qw"] = pose.qw().toDouble()
            payload["state"] = "TRACKING"
            payload["image"] = rgba
            payload["width"] = dstW
            payload["height"] = dstH
            payload["channels"] = 4
            payload["fx"] = fl[0].toDouble() * scale
            payload["fy"] = fl[1].toDouble() * scale
            payload["cx"] = pp[0].toDouble() * scale
            payload["cy"] = pp[1].toDouble() * scale
            // EventSink.success must be called on the main thread.
            mainHandler.post { sink.success(payload) }
        } finally {
            image.close()
        }
    }

    /// Downscales an ARCore YUV_420_888 sensor image to a dstW×dstH RGBA byte
    /// array via nearest-neighbour sampling — no intermediate full-res Bitmap, so
    /// the cost is exactly dstW*dstH samples (bounded, real-time). Honours each
    /// plane's row/pixel stride (chroma is commonly interleaved with pixelStride
    /// 2), reading absolutely so the buffers' positions are untouched.
    private fun yuvToRgba(image: Image, dstW: Int, dstH: Int): ByteArray {
        val srcW = image.width
        val srcH = image.height
        val yP = image.planes[0]
        val uP = image.planes[1]
        val vP = image.planes[2]
        val yBuf = yP.buffer
        val uBuf = uP.buffer
        val vBuf = vP.buffer
        val yRow = yP.rowStride; val yPix = yP.pixelStride
        val uRow = uP.rowStride; val uPix = uP.pixelStride
        val vRow = vP.rowStride; val vPix = vP.pixelStride

        val out = ByteArray(dstW * dstH * 4)
        var o = 0
        for (ty in 0 until dstH) {
            val sy = ty * srcH / dstH
            val uvY = sy / 2
            for (tx in 0 until dstW) {
                val sx = tx * srcW / dstW
                val uvX = sx / 2
                val y = yBuf.get(sy * yRow + sx * yPix).toInt() and 0xff
                val u = (uBuf.get(uvY * uRow + uvX * uPix).toInt() and 0xff) - 128
                val v = (vBuf.get(uvY * vRow + uvX * vPix).toInt() and 0xff) - 128
                val r = (y + 1.402 * v).toInt().coerceIn(0, 255)
                val g = (y - 0.344 * u - 0.714 * v).toInt().coerceIn(0, 255)
                val b = (y + 1.772 * u).toInt().coerceIn(0, 255)
                out[o++] = r.toByte()
                out[o++] = g.toByte()
                out[o++] = b.toByte()
                out[o++] = 255.toByte()
            }
        }
        return out
    }

    private fun probe(path: String): Map<String, Any> {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val width = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull() ?: 0
            val height = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull() ?: 0
            val durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            val frameRate = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)
                ?.toDoubleOrNull() ?: 0.0
            if (width <= 0 || height <= 0) {
                throw IllegalStateException("no decodable video stream in $path")
            }
            return mapOf(
                "width" to width,
                "height" to height,
                "frameRate" to frameRate,
                "durationSeconds" to durationMs / 1000.0,
            )
        } finally {
            retriever.release()
        }
    }

    private fun frameAt(
        path: String,
        timeUs: Long,
        targetWidth: Int,
        targetHeight: Int,
    ): ByteArray? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val frame = retriever.getFrameAtTime(
                timeUs,
                MediaMetadataRetriever.OPTION_CLOSEST,
            ) ?: return null
            val scaled =
                Bitmap.createScaledBitmap(frame, targetWidth, targetHeight, true)
            if (scaled !== frame) frame.recycle()
            val pixels = IntArray(targetWidth * targetHeight)
            scaled.getPixels(pixels, 0, targetWidth, 0, 0, targetWidth, targetHeight)
            scaled.recycle()
            // ARGB int → RGBA bytes, endianness-safe (Dart asserts exactly w*h*4).
            val out = ByteArray(targetWidth * targetHeight * 4)
            for (i in pixels.indices) {
                val px = pixels[i]
                val o = i * 4
                out[o] = ((px shr 16) and 0xff).toByte()     // R
                out[o + 1] = ((px shr 8) and 0xff).toByte()  // G
                out[o + 2] = (px and 0xff).toByte()          // B
                out[o + 3] = ((px shr 24) and 0xff).toByte() // A
            }
            return out
        } finally {
            retriever.release()
        }
    }

    override fun onDestroy() {
        bgExecutor.shutdown()
        super.onDestroy()
    }
}
