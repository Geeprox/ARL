from copy import deepcopy
from dataclasses import replace
import json
import unittest

from arl.contracts import encode
from arl.service_deployment import (ValidationFault, parse_configuration, parse_inventory, parse_manifest, strict_json)
from support import fixture, single


class ValidationTests(unittest.TestCase):
    def rejected(self, fn, value, code=None):
        with self.assertRaises(ValidationFault) as caught:
            fn(value)
        if code:
            self.assertEqual(caught.exception.code, code)

    def test_three_backends_roundtrip_existing_descriptor(self):
        for name in ("docker-catalog.json", "mac-native-catalog.json", "nas-catalog.json"):
            with self.subTest(name=name):
                m, c = single(name)
                m.descriptor.validate()
                self.assertEqual(parse_manifest(strict_json(encode(m.wire()))), m)
                self.assertEqual(parse_configuration(strict_json(encode(c.wire())), m), c)

    def test_json_duplicate_nonfinite_depth_encoding_and_size(self):
        for raw in (b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":Infinity}', b'\xff',
                    b'[]', b'{"a":1.0}', b'{"a":"\\ud800"}', b' ' * 65537,
                    ('{"a":' * 20 + '1' + '}' * 20).encode()):
            with self.subTest(raw_type=type(raw).__name__, bytes=len(raw)):
                self.rejected(strict_json, raw)

    def test_strict_field_types_and_unknown_fields(self):
        base = fixture()["manifests"][0]
        for key, bad in (("schema_version", True), ("schema_version", 2), ("name", "bad\nname"),
                         ("service_id", "friday"), ("icon_ref", "https://external.example/icon"),
                         ("revision", "main"), ("version", "1 0")):
            value = deepcopy(base); value[key] = bad
            with self.subTest(key=key, type=type(bad).__name__):
                self.rejected(parse_manifest, value)
        value = deepcopy(base); value["command"] = "install anything"
        self.rejected(parse_manifest, value, "unknown_or_missing_field")
        value = deepcopy(base); del value["health"]
        self.rejected(parse_manifest, value, "unknown_or_missing_field")

    def test_pinned_assets_and_no_entrypoint_or_mutable_image(self):
        base = fixture()["manifests"][0]
        for image in ("nginx:latest", "docker.io/library/nginx:1.0", "docker.io/library/nginx@sha256:" + "z" * 64,
                      "../unsafe@sha256:" + "a" * 64, "user:password@registry.invalid/image@sha256:" + "a" * 64):
            value = deepcopy(base); value["runtimes"][0]["image"] = image
            self.rejected(parse_manifest, value, "unpinned_image")
        value = deepcopy(base); value["runtimes"][0]["entrypoint"] = "/bin/sh"
        self.rejected(parse_manifest, value, "unknown_or_missing_field")
        value = fixture("mac-native-catalog.json")["manifests"][0]
        value["runtimes"][0]["artifact_sha256"] = "b" * 63
        self.rejected(parse_manifest, value, "invalid_digest")

    def test_repository_credentials_queries_and_path_traversal(self):
        for url in ("http://code.example.invalid/repo", "https://user:token@code.example.invalid/repo",
                    "https://code.example.invalid/repo?token=secret", "https://code.example.invalid/repo#fragment",
                    "https://code.example.invalid:bad/repo", "https://code.example.invalid/a/../repo",
                    "https://code.example.invalid/%2e%2e/repo", "https://code.example.invalid/repo\\other"):
            value = fixture()["manifests"][0]; value["repository_url"] = url
            self.rejected(parse_manifest, value, "invalid_https_url")

    def test_endpoint_health_and_port_validation(self):
        base = fixture()["manifests"][0]
        for path in ("//evil.example", "/../admin", "/health?token=x", "/%2e%2e", "relative"):
            value = deepcopy(base); value["health"]["endpoint"]["path"] = path
            self.rejected(parse_manifest, value)
        for key, val in (("expected_status", 500), ("timeout_ms", 5001), ("interval_ms", True), ("stale_after_ms", 10)):
            value = deepcopy(base); value["health"][key] = val
            self.rejected(parse_manifest, value)
        value = deepcopy(base); value["health"]["endpoint"]["port"] = "missing"
        self.rejected(parse_manifest, value, "invalid_endpoint_port")
        value = deepcopy(base); value["ports"][0]["protocol"] = "udp"
        self.rejected(parse_manifest, value, "invalid_endpoint_port")

    def test_arrays_duplicates_and_self_dependency(self):
        base = fixture()["manifests"][0]
        for key in ("runtimes", "ports", "mounts", "parameters", "dependencies"):
            value = deepcopy(base); value[key] += value[key]
            self.rejected(parse_manifest, value, "duplicate_entry")
        value = deepcopy(base); value["ports"] *= 17
        self.rejected(parse_manifest, value, "invalid_array")
        value = deepcopy(base); value["dependencies"][0]["service_id"] = value["service_id"]
        self.rejected(parse_manifest, value, "self_dependency")

    def test_closed_configuration_and_typed_values(self):
        m, _ = single()
        base = fixture()["configurations"][1]
        for key, val in (("READ_ONLY", 1), ("WORKERS", True), ("WORKERS", 100),
                         ("DISPLAY_MODE", "unlisted"), ("UNKNOWN", "value")):
            value = deepcopy(base); value["parameters"][key] = val
            self.rejected(lambda v: parse_configuration(v, m), value)
        for key in ("command", "secrets", "environment", "readiness", "registered"):
            value = deepcopy(base); value[key] = "host_observation"
            self.rejected(lambda v: parse_configuration(v, m), value, "unknown_or_missing_field")

    def test_secret_separation_and_no_plaintext_echo(self):
        base = fixture()["manifests"][0]
        for key in ("API_TOKEN", "PASSWORD", "PRIVATE_KEY", "MY_SECRET", "API_KEY"):
            value = deepcopy(base); value["parameters"][0]["key"] = key
            self.rejected(parse_manifest, value, "sensitive_or_invalid_parameter")
        m, _ = single("nas-catalog.json")
        value = fixture("nas-catalog.json")["configurations"][0]
        value["credential_refs"]["SERVICE_TOKEN"] = {"value": "secret-marker-must-not-echo"}
        with self.assertRaises(ValidationFault) as caught:
            parse_configuration(value, m)
        self.assertNotIn("secret-marker", str(caught.exception))

    def test_mount_paths_exposure_and_native_remapping(self):
        m, _ = single("docker-catalog.json", 0)
        for bad in ("relative", "/", "/a/../b", "/a/./b", "//volume/name", "/a\n/b", "/a\\b"):
            value = fixture()["configurations"][0]; value["mount_bindings"][0]["source"] = bad
            self.rejected(lambda v: parse_configuration(v, m), value)
        value = fixture()["configurations"][0]; value["port_bindings"][0]["exposure"] = "all_interfaces"
        self.rejected(lambda v: parse_configuration(v, m), value, "unsupported_value")
        native, _ = single("mac-native-catalog.json")
        value = fixture("mac-native-catalog.json")["configurations"][0]; value["port_bindings"][0]["host_port"] = 48080
        self.rejected(lambda v: parse_configuration(v, native), value, "native_port_remap_unsupported")

    def test_inventory_json_cannot_claim_host_authority(self):
        value = fixture()["inventory"]
        value["source"] = "host_observation"
        self.rejected(parse_inventory, value, "unsupported_value")
