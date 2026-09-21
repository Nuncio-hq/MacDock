APP = build/Build/Products/Debug/MacDock.app

xcodeproj:
	xcodegen

build: xcodeproj
	xcodebuild -project MacDock.xcodeproj -scheme MacDock -configuration Debug -derivedDataPath build build

run: build
	open $(APP)

clean:
	rm -rf build DerivedData MacDock.xcodeproj

.PHONY: xcodeproj build run clean
