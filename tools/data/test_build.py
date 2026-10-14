import base64
import ipaddress
import tempfile
import unittest
from pathlib import Path

from tools.data import build


class DomainParsingTests(unittest.TestCase):
    def test_gfwlist_syntax_and_skip_reasons(self):
        source = "\n".join(
            [
                "! comment",
                "[AutoProxy 0.2.9]",
                "@@||allow.example",
                "/regex.example/",
                "||Example.COM^/path",
                "|http://web.example/path",
                "|https://tls.example/path",
                ".dot.example",
                "bare.example/path",
                "192.0.2.1",
                "*.wild.example",
                "bad host",
                "example.com/duplicate",
            ]
        )

        domains, skipped = build.gfwlist_domains(source)

        self.assertEqual(
            domains,
            ["bare.example", "dot.example", "example.com", "tls.example", "web.example"],
        )
        self.assertEqual(
            skipped,
            {
                "comment": 1,
                "duplicate": 1,
                "header": 1,
                "invalid_domain": 1,
                "ip_address": 1,
                "regex": 1,
                "whitelist": 1,
                "wildcard": 1,
            },
        )

    def test_china_server_domain_extraction(self):
        self.assertEqual(
            build.china_domains(
                "# comment\nserver=/BaIdu.com/114.114.114.114\nserver=/apple.com/1.1.1.1\n"
            ),
            ["apple.com", "baidu.com"],
        )
        with self.assertRaisesRegex(ValueError, "expected server"):
            build.china_domains("address=/bad.example/1.1.1.1\n")


class CidrParsingTests(unittest.TestCase):
    def test_apnic_non_power_of_two_range_is_split_exactly(self):
        networks = build.apnic_networks("apnic|CN|ipv4|10.0.0.0|6|20260101|allocated\n")
        self.assertEqual(
            [str(network) for network in networks],
            ["10.0.0.0/30", "10.0.0.4/31"],
        )
        covered = {address for network in networks for address in network}
        self.assertEqual(covered, {ipaddress.IPv4Address(f"10.0.0.{n}") for n in range(6)})

    def test_adjacent_allocations_aggregate_without_changing_address_set(self):
        records = "\n".join(
            [
                "apnic|CN|ipv4|10.0.0.0|1|20260101|allocated",
                "apnic|CN|ipv4|10.0.0.1|1|20260101|allocated",
            ]
        )
        networks = build.apnic_networks(records)
        self.assertEqual([str(network) for network in networks], ["10.0.0.0/31"])
        self.assertEqual(
            {address for network in networks for address in network},
            {ipaddress.IPv4Address("10.0.0.0"), ipaddress.IPv4Address("10.0.0.1")},
        )

    def test_static_cidrs_normalize_32_sort_and_deduplicate(self):
        networks = build.static_networks(
            "10.0.0.2/32\n10.0.0.0/31\n10.0.0.2\n"
        )
        self.assertEqual(build.cidr_lines(networks), ["10.0.0.0/31", "10.0.0.2"])


class AppleSourceSemanticsTests(unittest.TestCase):
    def setUp(self):
        self.valid_lists = {
            "gfwlist.txt": ["google.com"] + [f"gfw{index}.example" for index in range(2999)],
            "chnlist.txt": ["baidu.com"] + [f"cn{index}.example" for index in range(49999)],
            "apple.txt": [f"cdn{index}.apple.com" for index in range(50)],
            "chnroute4.txt": ["114.114.114.114", "223.5.5.5"]
            + [str(ipaddress.IPv4Address(0x0A000000 + index)) for index in range(3000)],
            "gfw_static4.txt": ["10.0.0.0/8"],
        }

    def test_apple_subdomain_without_apex_passes_sanity_check(self):
        build.validate_outputs(self.valid_lists)
        self.assertNotIn("apple.com", self.valid_lists["apple.txt"])

    def test_generated_apple_list_does_not_add_apex(self):
        raw = {
            "gfwlist.b64": base64.b64encode(b"google.com\n"),
            "china-domains.conf": b"server=/baidu.com/114.114.114.114\n",
            "apple-domains.conf": b"server=/cdn.apple.com/114.114.114.114\n",
            "delegated-apnic-latest": (
                b"apnic|CN|ipv4|114.114.114.114|1|20260101|allocated\n"
                b"apnic|CN|ipv4|223.5.5.5|1|20260101|allocated\n"
            ),
            "telegram-cidr.txt": b"10.0.0.0/8\n",
        }
        metadata = {
            name: {"downloaded_at": "2026-01-01T00:00:00+00:00"}
            for name in build.SOURCES
        }

        minimums = {filename: 0 for filename in build.MIN_LINES}
        generated = build.build_outputs(raw, b"10.0.0.0/8\n", metadata, minimums)
        self.assertEqual(generated["apple.txt"], b"cdn.apple.com\n")
        self.assertNotIn("apple.com", generated["apple.txt"].decode().splitlines())

    def test_apple_list_without_apple_subdomains_fails_sanity_check(self):
        invalid = {
            **self.valid_lists,
            "apple.txt": [f"cdn{index}.other.example" for index in range(50)],
        }
        with self.assertRaisesRegex(ValueError, r"subdomain ending in \.apple\.com"):
            build.validate_outputs(invalid)


class OutputSafetyTests(unittest.TestCase):
    def test_sanity_failure_creates_no_output(self):
        raw = {
            "gfwlist.b64": base64.b64encode(b"not enough domains\n"),
            "china-domains.conf": b"server=/baidu.com/1.1.1.1\n",
            "apple-domains.conf": b"server=/apple.com/1.1.1.1\n",
            "delegated-apnic-latest": b"apnic|CN|ipv4|10.0.0.0|1|20260101|allocated\n",
            "telegram-cidr.txt": b"10.0.0.0/8\n",
        }
        metadata = {
            name: {"downloaded_at": "2026-01-01T00:00:00+00:00"}
            for name in build.SOURCES
        }

        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "must-not-exist"
            with self.assertRaisesRegex(ValueError, "gfwlist.txt"):
                build.write_baseline(output, raw, b"10.0.0.0/8\n", metadata)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
