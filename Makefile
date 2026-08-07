.PHONY: test demo format lint xcodeproj ios-build gateway-install gateway-check check

test:
	swift test

format:
	swiftformat .

lint:
	swiftformat --lint .

demo:
	swift run studio-demo

xcodeproj:
	ruby scripts/generate_xcodeproj.rb

ios-build: xcodeproj
	xcodebuild -project CreatorStudio.xcodeproj -scheme CreatorStudio -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

gateway-install:
	npm --prefix services/ai-gateway install

gateway-check:
	npm --prefix services/ai-gateway run check

check: lint test gateway-check ios-build
