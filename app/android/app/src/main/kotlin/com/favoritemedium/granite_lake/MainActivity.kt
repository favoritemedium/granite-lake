package com.favoritemedium.granite_lake

import android.os.Build
import android.os.Bundle
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.view.WindowManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.exifinterface.media.ExifInterface
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.InvalidAlgorithmParameterException
import java.security.KeyStore
import java.util.UUID
import javax.crypto.BadPaddingException
import javax.crypto.Cipher
import javax.crypto.IllegalBlockSizeException
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterFragmentActivity() {
	private val channelName = "granite_lake/biometric_gate"
	private val keyStoreProvider = "AndroidKeyStore"

	private var pendingResult: MethodChannel.Result? = null
	private var pendingCreateAliasForCleanup: String? = null

	override fun onCreate(savedInstanceState: Bundle?) {
		// Every screen in this app can show captured evidence photos or their
		// metadata. Block screenshots, screen recording, and the recent-apps
		// thumbnail for the whole activity rather than picking screens to
		// exempt.
		window.setFlags(
			WindowManager.LayoutParams.FLAG_SECURE,
			WindowManager.LayoutParams.FLAG_SECURE,
		)
		super.onCreate(savedInstanceState)
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
			.setMethodCallHandler { call, result ->
				when (call.method) {
					"createBiometricGate" -> createBiometricGate(call, result)
					"unlockBiometricGate" -> unlockBiometricGate(call, result)
					"deleteBiometricGate" -> deleteBiometricGate(call, result)
					"stripGpsExif" -> stripGpsExif(call, result)
					else -> result.notImplemented()
				}
			}
	}

	private fun createBiometricGate(call: MethodCall, result: MethodChannel.Result) {
		if (!ensureNoPendingOperation(result) || !ensureBiometricSupport(result)) {
			return
		}

		val payload = call.argument<String>("payload")
		if (payload.isNullOrEmpty()) {
			result.error("invalid_arguments", "Missing biometric gate payload.", null)
			return
		}

		val alias = "granite_gate_${UUID.randomUUID()}"
		pendingResult = result
		try {
			generateSecretKey(alias)
			val cipher = initEncryptCipher(alias)
			pendingCreateAliasForCleanup = alias
			authenticate(
				title = "Bind biometrics",
				subtitle = "Create a secure biometric gate for Granite Lake.",
				cipher = cipher,
				onSuccess = { authenticatedCipher ->
					val ciphertext = authenticatedCipher.doFinal(payload.toByteArray(Charsets.UTF_8))
					pendingCreateAliasForCleanup = null
					finishSuccess(
						mapOf(
							"alias" to alias,
							"ciphertextBase64" to android.util.Base64.encodeToString(
								ciphertext,
								android.util.Base64.NO_WRAP,
							),
							"ivBase64" to android.util.Base64.encodeToString(
								authenticatedCipher.iv,
								android.util.Base64.NO_WRAP,
							),
						),
					)
				},
			)
		} catch (error: KeyPermanentlyInvalidatedException) {
			pendingCreateAliasForCleanup = null
			deleteKeyIfPresent(alias)
			finishError("biometric_changed", "Biometrics changed on this device. Re-bind required.")
		} catch (error: Exception) {
			pendingCreateAliasForCleanup = null
			deleteKeyIfPresent(alias)
			finishError("binding_failed", error.message ?: "Biometric gate creation failed.")
		}
	}

	private fun unlockBiometricGate(call: MethodCall, result: MethodChannel.Result) {
		if (!ensureNoPendingOperation(result) || !ensureBiometricSupport(result)) {
			return
		}

		val alias = call.argument<String>("alias")
		val ciphertextBase64 = call.argument<String>("ciphertextBase64")
		val ivBase64 = call.argument<String>("ivBase64")
		val title = call.argument<String>("title")?.takeIf { it.isNotBlank() } ?: "Unlock secure session"
		val subtitle = call.argument<String>("subtitle")?.takeIf { it.isNotBlank() }
			?: "Verify biometrics to unlock Granite Lake."

		if (alias.isNullOrBlank() || ciphertextBase64.isNullOrBlank() || ivBase64.isNullOrBlank()) {
			result.error("invalid_arguments", "Missing biometric gate payload.", null)
			return
		}

		pendingResult = result
		try {
			val iv = android.util.Base64.decode(ivBase64, android.util.Base64.DEFAULT)
			val ciphertext = android.util.Base64.decode(ciphertextBase64, android.util.Base64.DEFAULT)
			val cipher = initDecryptCipher(alias, iv)
			authenticate(
				title = title,
				subtitle = subtitle,
				cipher = cipher,
				onSuccess = { authenticatedCipher ->
					val plaintext = authenticatedCipher.doFinal(ciphertext)
					finishSuccess(String(plaintext, Charsets.UTF_8))
				},
			)
		} catch (error: KeyPermanentlyInvalidatedException) {
			finishError("biometric_changed", "Biometrics changed on this device. Re-bind required.")
		} catch (error: UnrecoverableBiometricGateException) {
			finishError(error.code, error.message)
		} catch (error: Exception) {
			finishError("unlock_failed", error.message ?: "Biometric gate unlock failed.")
		}
	}

	private fun deleteBiometricGate(call: MethodCall, result: MethodChannel.Result) {
		val alias = call.argument<String>("alias")
		if (alias.isNullOrBlank()) {
			result.success(null)
			return
		}

		deleteKeyIfPresent(alias)
		result.success(null)
	}

	// GPS lat/long for attestation come from Geolocator, not from image EXIF
	// (see capture_screen.dart) - the EXIF GPS tag on a camera JPEG is only
	// ever an incidental side effect of the OS/camera writing it when device
	// location is on. Android's MediaProvider redacts that EXIF GPS block
	// (zeroes the tag values in place, same file size) for any reader that
	// lacks ACCESS_MEDIA_LOCATION - including generic hash/share/upload
	// tools, not just off-device transfers - which silently changes the
	// file's hash after it was already attested. Stripping GPS at capture
	// time, before hashing, means there's nothing left for that redaction
	// to touch: the attested file and every later copy of it stay identical
	// forever, on any reader.
	private fun stripGpsExif(call: MethodCall, result: MethodChannel.Result) {
		val path = call.argument<String>("path")
		if (path.isNullOrEmpty()) {
			result.error("invalid_arguments", "Missing image path.", null)
			return
		}

		try {
			val exif = ExifInterface(path)
			for (tag in gpsExifTags) {
				exif.setAttribute(tag, null)
			}
			exif.saveAttributes()
			result.success(null)
		} catch (error: Exception) {
			result.error("strip_gps_exif_failed", error.message ?: "Could not strip GPS EXIF data.", null)
		}
	}

	private val gpsExifTags = listOf(
		ExifInterface.TAG_GPS_VERSION_ID,
		ExifInterface.TAG_GPS_LATITUDE_REF,
		ExifInterface.TAG_GPS_LATITUDE,
		ExifInterface.TAG_GPS_LONGITUDE_REF,
		ExifInterface.TAG_GPS_LONGITUDE,
		ExifInterface.TAG_GPS_ALTITUDE_REF,
		ExifInterface.TAG_GPS_ALTITUDE,
		ExifInterface.TAG_GPS_TIMESTAMP,
		ExifInterface.TAG_GPS_DATESTAMP,
		ExifInterface.TAG_GPS_SATELLITES,
		ExifInterface.TAG_GPS_STATUS,
		ExifInterface.TAG_GPS_MEASURE_MODE,
		ExifInterface.TAG_GPS_DOP,
		ExifInterface.TAG_GPS_SPEED_REF,
		ExifInterface.TAG_GPS_SPEED,
		ExifInterface.TAG_GPS_TRACK_REF,
		ExifInterface.TAG_GPS_TRACK,
		ExifInterface.TAG_GPS_IMG_DIRECTION_REF,
		ExifInterface.TAG_GPS_IMG_DIRECTION,
		ExifInterface.TAG_GPS_MAP_DATUM,
		ExifInterface.TAG_GPS_DEST_LATITUDE_REF,
		ExifInterface.TAG_GPS_DEST_LATITUDE,
		ExifInterface.TAG_GPS_DEST_LONGITUDE_REF,
		ExifInterface.TAG_GPS_DEST_LONGITUDE,
		ExifInterface.TAG_GPS_DEST_BEARING_REF,
		ExifInterface.TAG_GPS_DEST_BEARING,
		ExifInterface.TAG_GPS_DEST_DISTANCE_REF,
		ExifInterface.TAG_GPS_DEST_DISTANCE,
		ExifInterface.TAG_GPS_PROCESSING_METHOD,
		ExifInterface.TAG_GPS_AREA_INFORMATION,
		ExifInterface.TAG_GPS_DIFFERENTIAL,
		ExifInterface.TAG_GPS_H_POSITIONING_ERROR,
	)

	private fun authenticate(
		title: String,
		subtitle: String,
		cipher: Cipher,
		onSuccess: (Cipher) -> Unit,
	) {
		val executor = ContextCompat.getMainExecutor(this)
		val prompt = BiometricPrompt(
			this,
			executor,
			object : BiometricPrompt.AuthenticationCallback() {
				override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
					finishError(
						when (errorCode) {
							BiometricPrompt.ERROR_CANCELED,
							BiometricPrompt.ERROR_NEGATIVE_BUTTON,
							BiometricPrompt.ERROR_USER_CANCELED -> "auth_cancelled"
							else -> "auth_failed"
						},
						errString.toString(),
					)
				}

				override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
					val authenticatedCipher = result.cryptoObject?.cipher
					if (authenticatedCipher == null) {
						finishError("auth_failed", "Biometric prompt did not return a crypto object.")
						return
					}

					try {
						onSuccess(authenticatedCipher)
					} catch (error: KeyPermanentlyInvalidatedException) {
						finishError(
							"biometric_changed",
							"Biometrics changed on this device. Re-bind required.",
						)
					} catch (error: BadPaddingException) {
						finishError("gate_missing", "Stored biometric gate could not be unlocked.")
					} catch (error: IllegalBlockSizeException) {
						finishError("gate_missing", "Stored biometric gate could not be unlocked.")
					} catch (error: Exception) {
						finishError("auth_failed", error.message ?: "Biometric authentication failed.")
					}
				}
			},
		)

		val promptInfo = BiometricPrompt.PromptInfo.Builder()
			.setTitle(title)
			.setSubtitle(subtitle)
			.setNegativeButtonText("Cancel")
			.apply {
				if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
					setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
				}
			}
			.build()

		prompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(cipher))
	}

	private fun ensureNoPendingOperation(result: MethodChannel.Result): Boolean {
		if (pendingResult == null) {
			return true
		}

		result.error("operation_pending", "Another biometric operation is already in progress.", null)
		return false
	}

	private fun ensureBiometricSupport(result: MethodChannel.Result): Boolean {
		val biometricManager = BiometricManager.from(this)
		val canAuthenticate = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
			biometricManager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
		} else {
			@Suppress("DEPRECATION")
			biometricManager.canAuthenticate()
		}

		return when (canAuthenticate) {
			BiometricManager.BIOMETRIC_SUCCESS -> true
			BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> {
				result.error("biometric_unavailable", "No biometrics are enrolled on this device.", null)
				false
			}
			BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE,
			BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> {
				result.error("biometric_unavailable", "Biometric authentication is unavailable on this device.", null)
				false
			}
			else -> {
				result.error("biometric_unavailable", "Biometric authentication is unavailable.", null)
				false
			}
		}
	}

	private fun generateSecretKey(alias: String) {
		val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, keyStoreProvider)
		val builder = KeyGenParameterSpec.Builder(
			alias,
			KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
		)
			.setBlockModes(KeyProperties.BLOCK_MODE_GCM)
			.setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
			.setUserAuthenticationRequired(true)
			.setInvalidatedByBiometricEnrollment(true)
			.setRandomizedEncryptionRequired(true)
			.setUserAuthenticationValidityDurationSeconds(-1)

		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
			builder.setUserAuthenticationParameters(
				0,
				KeyProperties.AUTH_BIOMETRIC_STRONG,
			)
		}

		keyGenerator.init(builder.build())
		keyGenerator.generateKey()
	}

	private fun initEncryptCipher(alias: String): Cipher {
		val cipher = Cipher.getInstance("AES/GCM/NoPadding")
		cipher.init(Cipher.ENCRYPT_MODE, loadSecretKey(alias))
		return cipher
	}

	private fun initDecryptCipher(alias: String, iv: ByteArray): Cipher {
		val cipher = Cipher.getInstance("AES/GCM/NoPadding")
		try {
			cipher.init(
				Cipher.DECRYPT_MODE,
				loadSecretKey(alias),
				GCMParameterSpec(128, iv),
			)
		} catch (error: InvalidAlgorithmParameterException) {
			throw UnrecoverableBiometricGateException(
				"gate_missing",
				"Stored biometric gate could not be unlocked.",
			)
		}
		return cipher
	}

	private fun loadSecretKey(alias: String): SecretKey {
		val keyStore = KeyStore.getInstance(keyStoreProvider).apply { load(null) }
		val secretKey = keyStore.getKey(alias, null) as? SecretKey
		if (secretKey == null) {
			throw UnrecoverableBiometricGateException(
				"gate_missing",
				"Stored biometric gate could not be found.",
			)
		}
		return secretKey
	}

	private fun deleteKeyIfPresent(alias: String) {
		val keyStore = KeyStore.getInstance(keyStoreProvider).apply { load(null) }
		if (keyStore.containsAlias(alias)) {
			keyStore.deleteEntry(alias)
		}
	}

	private fun finishSuccess(payload: Any?) {
		val result = pendingResult ?: return
		pendingResult = null
		pendingCreateAliasForCleanup = null
		result.success(payload)
	}

	private fun finishError(code: String, message: String) {
		val cleanupAlias = pendingCreateAliasForCleanup
		pendingCreateAliasForCleanup = null
		if (cleanupAlias != null) {
			deleteKeyIfPresent(cleanupAlias)
		}

		val result = pendingResult ?: return
		pendingResult = null
		result.error(code, message, null)
	}
}

private class UnrecoverableBiometricGateException(
	val code: String,
	override val message: String,
) : IllegalStateException(message)