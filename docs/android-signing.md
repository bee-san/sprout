# Android signing

Keep one signing key for installable updates and Google OAuth fingerprint registration. Do not commit it or the associated passwords.

Create a key locally:

```sh
keytool -genkeypair -v -keystore android/app/release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias timebud
```

Create `android/key.properties`:

```properties
storeFile=release.jks
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=timebud
```

Use Java properties escaping for backslashes or newlines in passwords. Both files are git-ignored. Back up the signing key securely; losing it prevents updates to installations signed with that key.

For GitHub Actions, configure repository secrets:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64-encoded keystore bytes |
| `ANDROID_STORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_PASSWORD` | Key password |
| `ANDROID_KEY_ALIAS` | `timebud` or your chosen alias |

The build workflow restores the key only for the Android build. Without these secrets it builds a development-key-signed preview APK; different clean CI runners may use different debug keys, so those previews may require uninstalling the previous preview before installation. Export your data and sync before doing so.

Android's Google setup screen displays the signing fingerprint of the installed build. Register that SHA-1 fingerprint with the Android OAuth client in your Google Cloud project.
