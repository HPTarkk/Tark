from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "release-tark.yml"


class ReleaseWorkflowProvenanceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.text = WORKFLOW.read_text(encoding="utf-8")

    def test_release_uses_quality_gate_flutter_sdk(self) -> None:
        self.assertIn('flutter-version: "3.47.1"', self.text)

    def test_release_commit_exists_before_provenance_and_build(self) -> None:
        commit = self.text.index("- name: Create local release commit")
        provenance = self.text.index("- name: Resolve exact build provenance")
        android = self.text.index("- name: Build signed Android APK and App Bundle")
        pwa = self.text.index("- name: Build guest PWA archive")
        push = self.text.index("- name: Push release commit to main")

        self.assertLess(commit, provenance)
        self.assertLess(provenance, android)
        self.assertLess(android, pwa)
        self.assertLess(pwa, push)

    def test_all_release_artifacts_embed_exact_clean_provenance(self) -> None:
        self.assertIn('sha="$(git rev-parse HEAD)"', self.text)
        self.assertIn('^[' + '0-9a-f' + ']{40}$', self.text)
        self.assertIn('--dart-define=GIT_COMMIT=${{ steps.provenance.outputs.commit_sha }}', self.text)
        self.assertIn('--dart-define=GIT_DIRTY=false', self.text)
        self.assertIn('--dart-define=BUILD_TIMESTAMP=${{ steps.provenance.outputs.built_at }}', self.text)
        self.assertGreaterEqual(self.text.count("provenance_args=("), 2)
        self.assertIn("flutter build apk --release --split-per-abi", self.text)
        self.assertIn("flutter build appbundle --release", self.text)
        self.assertIn("flutter build web --release -t lib/main_guest.dart", self.text)

    def test_dirty_release_source_is_rejected(self) -> None:
        self.assertIn("git status --porcelain --untracked-files=no", self.text)
        self.assertIn("Release source has tracked changes after the release commit", self.text)
        self.assertIn("git diff --exit-code", self.text)
        self.assertIn("git diff --check", self.text)


if __name__ == "__main__":
    unittest.main()
