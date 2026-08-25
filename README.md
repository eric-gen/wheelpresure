Mac: build and archive
cd wheelpresure/flutter_application_1
flutter build ipa          # needs signing set up in Xcode first
Upload: either Xcode → Product → Archive → Distribute App → App Store Connect, or xcrun altool/Transporter with the .ipa from build/ios/ipa/
In App Store Connect (website): create an app record with bundle ID com.vaengineering.tirepressure (already set in the repo)
After Apple's automatic review of the build (~minutes to a day), add yourself as Internal Tester → install TestFlight on the iPhone → the app appears, updates push like a normal app
Internal testers (up to 100) need no review; you just invite them by email