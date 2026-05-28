# Makefile — 与 build.sh 功能等价的 make 版本
# 用法：
#   make           出 .tipa
#   make build     仅 xcodebuild（不签名、不打包）
#   make sign      build + ldid 签名（不打包）
#   make clean

APP_NAME       = livestream
SCHEME         = livestream
DERIVED        = build
APP            = $(DERIVED)/Build/Products/Release-iphoneos/$(APP_NAME).app
SIGN_SCRIPT    = ./sign-tipa.sh

.PHONY: all build sign tipa clean

all: tipa

build:
	xcodebuild -scheme $(SCHEME) \
	    -derivedDataPath $(DERIVED) \
	    -destination 'generic/platform=iOS' \
	    -sdk iphoneos \
	    -configuration Release \
	    -xcconfig trollstore.xcconfig

sign: build
	$(SIGN_SCRIPT) $(APP)

tipa: sign
	rm -rf Payload $(APP_NAME).ipa $(APP_NAME).tipa
	mkdir Payload
	cp -r $(APP) Payload/
	zip -qr $(APP_NAME).ipa Payload
	cp $(APP_NAME).ipa $(APP_NAME).tipa
	rm -rf Payload
	@echo
	@echo "==> $(APP_NAME).tipa ready ($$(du -h $(APP_NAME).tipa | cut -f1))"

clean:
	rm -rf $(DERIVED) Payload $(APP_NAME).ipa $(APP_NAME).tipa
