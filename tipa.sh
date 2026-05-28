```sh
APP=build/Build/Products/Release-iphoneos/livestream.app
rm -rf Payload livestream.ipa livestream.tipa
mkdir Payload && cp -r "$APP" Payload/
zip -qr livestream.ipa Payload
cp livestream.ipa livestream.tipa
rm -rf Payload
ls -lh livestream.tipa
```