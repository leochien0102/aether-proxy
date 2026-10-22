"""Exercise rule-data conversion and the docs/08 sanity checks without downloads."""

import base64
import ipaddress
import tempfile
import unittest
from pathlib import Path

from tools.data import build


# Independent expected list: deleting a generator constant must break these tests.
EXPECTED_PUBLIC_DNS4 = [
    "1.0.0.1",
    "1.1.1.1",
    "8.8.4.4",
    "8.8.8.8",
    "9.9.9.9",
    "149.112.112.112",
    "208.67.220.220",
    "208.67.222.222",
]


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
        expected = EXPECTED_PUBLIC_DNS4[:5] + ["10.0.0.0/31", "10.0.0.2"] + EXPECTED_PUBLIC_DNS4[5:]
        self.assertEqual(build.cidr_lines(networks), expected)


class AppleSourceSemanticsTests(unittest.TestCase):
    def setUp(self):
        self.valid_lists = {
            "gfwlist.txt": ["google.com"] + [f"gfw{index}.example" for index in range(2999)],
            "chnlist.txt": ["baidu.com"] + [f"cn{index}.example" for index in range(49999)],
            "apple.txt": [f"cdn{index}.apple.com" for index in range(50)],
            "chnroute4.txt": ["114.114.114.114", "223.5.5.5"]
            + [str(ipaddress.IPv4Address(0x0A000000 + index)) for index in range(3000)],
            "gfw_static4.txt": EXPECTED_PUBLIC_DNS4 + ["10.0.0.0/8"],
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


class StaticDnsTests(unittest.TestCase):
    def setUp(self):
        self.raw = {
            "gfwlist.b64": base64.b64encode(b"google.com\n"),
            "china-domains.conf": b"server=/baidu.com/114.114.114.114\n",
            "apple-domains.conf": b"server=/cdn.apple.com/114.114.114.114\n",
            "delegated-apnic-latest": (
                b"apnic|CN|ipv4|114.114.114.114|1|20260101|allocated\n"
                b"apnic|CN|ipv4|223.5.5.5|1|20260101|allocated\n"
            ),
            "telegram-cidr.txt": b"",
        }
        self.metadata = {
            name: {"downloaded_at": "2026-01-01T00:00:00+00:00"}
            for name in build.SOURCES
        }

    def generate(self, telegram_source):
        self.raw["telegram-cidr.txt"] = telegram_source
        return build.build_outputs(self.raw, telegram_source, self.metadata, minimums={})

    def test_empty_telegram_outputs_exactly_sorted_public_dns(self):
        generated = self.generate(b"")
        expected = ("\n".join(EXPECTED_PUBLIC_DNS4) + "\n").encode()
        self.assertEqual(generated["gfw_static4.txt"], expected)

    def test_telegram_subnet_covers_dns_without_duplicate(self):
        generated = self.generate(b"8.8.8.0/24\n")
        expected = ["8.8.8.0/24" if address == "8.8.8.8" else address for address in EXPECTED_PUBLIC_DNS4]
        self.assertEqual(generated["gfw_static4.txt"], ("\n".join(expected) + "\n").encode())
        # build_outputs also runs the sanity check: subnet coverage must pass it.
        self.assertNotIn(b"8.8.8.8\n", generated["gfw_static4.txt"])

    def test_sanity_rejects_each_missing_builtin_dns(self):
        generated = self.generate(b"")
        outputs = {name: content.decode().splitlines() for name, content in generated.items() if name.endswith(".txt")}
        for address in EXPECTED_PUBLIC_DNS4:
            with self.subTest(address=address):
                incomplete = {
                    **outputs,
                    "gfw_static4.txt": [value for value in EXPECTED_PUBLIC_DNS4 if value != address],
                }
                with self.assertRaises(ValueError) as raised:
                    build.validate_outputs(incomplete, minimums={})
                self.assertEqual(str(raised.exception), f"gfw_static4.txt: must cover {address}")

    def test_packaged_baseline_matches_generator_and_preserves_telegram(self):
        source = Path(__file__).with_name("gfw_static4.src.txt").read_bytes()
        generated = self.generate(source)["gfw_static4.txt"]
        root = Path(__file__).resolve().parents[2]
        baseline = (root / "aether-proxy/files/data/gfw_static4.txt").read_bytes()
        self.assertEqual(baseline, generated)
        telegram = [line for line in baseline.decode().splitlines() if line not in EXPECTED_PUBLIC_DNS4]
        self.assertEqual(
            telegram,
            [
                "91.105.192.0/23",
                "91.108.4.0/22",
                "91.108.8.0/21",
                "91.108.16.0/21",
                "91.108.56.0/22",
                "149.154.160.0/20",
                "185.76.151.0/24",
            ],
        )
        self.assertEqual(len(baseline.decode().splitlines()), 15)


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
