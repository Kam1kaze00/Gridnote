# Gridnote for iPad

Gridnote bundles the notebook, PDF renderer and English text recognition on the iPad. The first launch works offline. The Files picker opens notebooks and PDFs. In PDF Preview, **Share or save PDF** opens the iPad share sheet, including Save to Files. Use **Notebook menu → Download editable notebook** for a backup you can keep editing.

## Build and test

Use a Mac with Xcode 26 or later, the iPadOS SDK, an iPad simulator, Python 3 and XcodeGen. From the repository root, run the following commands.

```sh
iPad/prepare.sh
open iPad/Gridnote.xcodeproj
```

Choose the Gridnote scheme and an iPad simulator. Run the app with **Product → Run** or the lecture workflow with **Product → Test**. The first preparation downloads libraries and checks their hashes. Run the preparation script again after changing the web editor.

The GitHub iPad check builds an unsigned device archive and tests opening an exercise, PDF export and reopening saved work on a 13-inch iPad simulator. Its artifacts include screenshots and test results. The unsigned archive is for build verification. A distribution-signed build is required for TestFlight and the App Store.

## App Store Connect draft

| Field | Proposed entry |
| --- | --- |
| Name | Gridnote |
| Subtitle | Handwriting and PDF notebooks |
| Primary category | Education |
| Price | Free |
| Keywords | notes,handwriting,grid paper,lecture,worksheet,stylus,Apple Pencil,math |
| Support URL | https://github.com/Kam1kaze00/Gridnote/issues |
| Privacy policy URL | https://kam1kaze00.github.io/Gridnote/guide.html#ipad-privacy |

**Description**

Write directly on an exercise, a lecture slide or a blank sheet of grid paper. Paste a screenshot, open a PDF or take a photo of a worksheet. Keep the question and your handwritten solution together.

Choose a writing tip, mark up a diagram or add a table. Switch between grid, ruled, dotted and plain paper. Your notebook saves on your iPad as you work. Export an A4 PDF to hand in, or save an editable copy to Files for your next study session.

**Review notes**

No sign-in is required. Tap New notebook, then open the notebook menu and select Open sample exercise to try the circuit worksheet. Preview PDF opens the finished pages. Share or save PDF opens the system sheet. Camera access is requested when adding a photo.

## First submission

1. Enroll in the Apple Developer Program or accept an invitation to a team with publishing access. The Account Holder completes Apple's identity and agreement steps.
2. In Xcode, choose that team under **Signing & Capabilities**. Register the final bundle ID. The project currently proposes `app.gridnote.notebook.ipad`. Create an iOS app record in App Store Connect using the same ID.
3. Archive for a generic iOS device and choose **Distribute App → App Store Connect**. Test the signed build in TestFlight on a physical iPad, including pressure, palm rejection, the rear camera, the Files picker and sharing.
4. Add the store text, a 13-inch iPad screenshot from the release candidate, support and privacy URLs, review contact, age rating and availability. Check Apple's privacy questions against the submitted build. Select the processed build and submit for review.

[Apple enrollment](https://developer.apple.com/programs/enroll/) · [Create an app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/) · [Submit for review](https://developer.apple.com/app-store/submitting/)
