#!/usr/bin/env python3
"""Writes the "Sync Clipboard" shortcut as an unsigned .shortcut plist.

The shortcut is three actions: Get Clipboard, the app's Sync Clipboard intent
fed with that text, and Copy to Clipboard fed with the intent's result. iOS
imports only signed shortcut files, and signing needs macOS (`shortcuts sign`),
so the CI workflow runs this and signs the output on its macOS runner.

The App Intent action names the app by bundle id and team, which differ per
signing identity: the sideloaded app is `XTL-<id>.net.jeedup.Tether` under the
personal team, the App Store app is `net.jeedup.Tether` under upstream's.
"""

import argparse
import plistlib
import uuid


def attachment(output_uuid: str, output_name: str) -> dict:
    """A text field whose whole content is another action's output."""
    return {
        "Value": {
            "attachmentsByRange": {
                "{0, 1}": {
                    "OutputName": output_name,
                    "OutputUUID": output_uuid,
                    "Type": "ActionOutput",
                }
            },
            "string": "￼",
        },
        "WFSerializationType": "WFTextTokenString",
    }


def build(bundle_id: str, team_id: str) -> dict:
    get_uuid = str(uuid.uuid4()).upper()
    sync_uuid = str(uuid.uuid4()).upper()
    return {
        "WFWorkflowClientVersion": "2607.0.3",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {
            "WFWorkflowIconGlyphNumber": 59511,
            "WFWorkflowIconStartColor": 431817727,
        },
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowHasShortcutInputVariables": False,
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowTypes": [],
        "WFWorkflowActions": [
            {
                "WFWorkflowActionIdentifier": "is.workflow.actions.getclipboard",
                "WFWorkflowActionParameters": {"UUID": get_uuid},
            },
            {
                "WFWorkflowActionIdentifier": "is.workflow.actions.appintent",
                "WFWorkflowActionParameters": {
                    "AppIntentDescriptor": {
                        "AppIntentIdentifier": "SyncClipboardIntent",
                        "BundleIdentifier": bundle_id,
                        "Name": "Sync Clipboard",
                        "TeamIdentifier": team_id,
                    },
                    "UUID": sync_uuid,
                    "text": attachment(get_uuid, "Clipboard"),
                },
            },
            {
                "WFWorkflowActionIdentifier": "is.workflow.actions.setclipboard",
                "WFWorkflowActionParameters": {
                    "WFInput": attachment(sync_uuid, "Sync Clipboard"),
                },
            },
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("-o", "--output", required=True, help="path of the .shortcut file to write")
    args = parser.parse_args()
    with open(args.output, "wb") as out:
        plistlib.dump(build(args.bundle_id, args.team_id), out, fmt=plistlib.FMT_BINARY)
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
