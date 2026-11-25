"""Exercise rule-data conversion and the docs/08 sanity checks without downloads."""

import base64
import hashlib
import ipaddress
import json
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


def parse_sources_md(text: str) -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    actual: dict[str, list[str]] = {}
    reference: dict[str, list[str]] = {}
    section = "actual"
    for line in text.splitlines():
        if line.startswith("## Upstream reference"):
            section = "reference"
            continue
        if line.startswith("## "):
            section = "other"
            continue
        if not line.startswith("| `"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        key = cells[0].strip("`")
        if section == "actual":
            actual[key] = cells[1:]
        elif section == "reference":
            reference[key] = cells[1:]
    return actual, reference


class StaticSourceProvenanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        gfw_lines = ["google.com"] + [f"gfw{index}.example" for index in range(2999)]
        china_lines = ["server=/baidu.com/114.114.114.114"] + [
            f"server=/cn{index}.example/114.114.114.114" for index in range(49999)
        ]
        apple_lines = [f"server=/cdn{index}.apple.com/114.114.114.114" for index in range(50)]
        apnic_lines = [
            "apnic|CN|ipv4|114.114.114.114|1|20260101|allocated",
            "apnic|CN|ipv4|223.5.5.5|1|20260101|allocated",
        ] + [
            f"apnic|CN|ipv4|{ipaddress.IPv4Address(0x0A000000 + index * 2)}|1|20260101|allocated"
            for index in range(3000)
        ]
        cls.base_raw = {
            "gfwlist.b64": base64.b64encode(("\n".join(gfw_lines) + "\n").encode("ascii")),
            "china-domains.conf": ("\n".join(china_lines) + "\n").encode("ascii"),
            "apple-domains.conf": ("\n".join(apple_lines) + "\n").encode("ascii"),
            "delegated-apnic-latest": ("\n".join(apnic_lines) + "\n").encode("ascii"),
        }
        cls.base_timestamps = {
            "gfwlist.b64": "2026-10-01T00:00:01+00:00",
            "china-domains.conf": "2026-10-01T00:00:02+00:00",
            "apple-domains.conf": "2026-10-01T00:00:03+00:00",
            "delegated-apnic-latest": "2026-10-01T00:00:04+00:00",
        }

    def run_offline_build(
        self, root: Path, label: str, static_path: Path,
        telegram_bytes: bytes, telegram_timestamp: str,
    ) -> tuple[dict[str, int], dict[str, bytes], dict[str, list[str]], dict[str, list[str]]]:
        cache_dir = root / f"cache-{label}"
        out_dir = root / f"out-{label}"
        cache_dir.mkdir(parents=True, exist_ok=True)

        raw = {**self.base_raw, "telegram-cidr.txt": telegram_bytes}
        timestamps = {**self.base_timestamps, "telegram-cidr.txt": telegram_timestamp}
        for name, content in raw.items():
            (cache_dir / name).write_bytes(content)
            (cache_dir / f"{name}.json").write_text(
                json.dumps({"downloaded_at": timestamps[name]}, sort_keys=True) + "\n",
                encoding="utf-8",
            )

        counts = build.build_to_dir(out_dir, static_path, cache_dir)
        files = {path.name: path.read_bytes() for path in sorted(out_dir.iterdir())}
        actual, reference = parse_sources_md(files["SOURCES.md"].decode("utf-8"))
        return counts, files, actual, reference

    def test_changing_reference_leaves_static_output_and_input_hash_unchanged(self):
        root_repo = Path(__file__).resolve().parents[2]
        default_static_path = build.DEFAULT_STATIC_SOURCE_PATH
        default_static_bytes = default_static_path.read_bytes()
        packaged_static = (root_repo / "aether-proxy/files/data/gfw_static4.txt").read_bytes()
        ref_a = b"91.108.4.0/22\n"
        ref_b = b"91.108.4.0/22\n149.154.160.0/20\n"
        ts_a = "2026-10-01T00:00:05+00:00"
        ts_b = "2026-10-02T12:34:56+00:00"

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            counts_a, files_a, actual_a, ref_rows_a = self.run_offline_build(
                root, "ref-a", default_static_path, ref_a, ts_a,
            )
            counts_b, files_b, actual_b, ref_rows_b = self.run_offline_build(
                root, "ref-b", default_static_path, ref_b, ts_b,
            )

        local_sha = f"`{hashlib.sha256(default_static_bytes).hexdigest()}`"
        ref_a_sha = f"`{hashlib.sha256(ref_a).hexdigest()}`"
        ref_b_sha = f"`{hashlib.sha256(ref_b).hexdigest()}`"

        self.assertEqual(files_a["gfw_static4.txt"], files_b["gfw_static4.txt"])
        self.assertEqual(files_a["gfw_static4.txt"], packaged_static)
        self.assertEqual(counts_a["gfw_static4.txt"], 15)
        self.assertEqual(counts_b["gfw_static4.txt"], 15)

        self.assertEqual(actual_a["gfw_static4.txt"], actual_b["gfw_static4.txt"])
        self.assertEqual(
            actual_a["gfw_static4.txt"][0],
            f"`{build.STATIC_SOURCE_REPO_PATH}` (+ built-in `PUBLIC_DNS4`)",
        )
        self.assertNotIn(build.SOURCES["telegram-cidr.txt"], actual_a["gfw_static4.txt"][0])
        self.assertEqual(actual_a["gfw_static4.txt"][1], "N/A (local repo input)")
        self.assertEqual(actual_a["gfw_static4.txt"][2], local_sha)
        self.assertEqual(actual_a["gfw_static4.txt"][4], "15")

        self.assertEqual(ref_rows_a["gfw_static4.txt"][0], build.SOURCES["telegram-cidr.txt"])
        self.assertEqual(ref_rows_a["gfw_static4.txt"][1], ts_a)
        self.assertEqual(ref_rows_a["gfw_static4.txt"][2], ref_a_sha)
        self.assertIn(f"`{build.STATIC_SOURCE_REPO_PATH}`", ref_rows_a["gfw_static4.txt"][3])
        self.assertEqual(ref_rows_b["gfw_static4.txt"][0], build.SOURCES["telegram-cidr.txt"])
        self.assertEqual(ref_rows_b["gfw_static4.txt"][1], ts_b)
        self.assertEqual(ref_rows_b["gfw_static4.txt"][2], ref_b_sha)
        self.assertIn(f"`{build.STATIC_SOURCE_REPO_PATH}`", ref_rows_b["gfw_static4.txt"][3])
        self.assertNotEqual(ref_rows_a["gfw_static4.txt"][2], ref_rows_b["gfw_static4.txt"][2])

        for name, (source, license_name) in build.OUTPUT_SOURCES.items():
            self.assertEqual(files_a[name], files_b[name])
            self.assertEqual(actual_a[name], actual_b[name])
            self.assertEqual(
                actual_a[name],
                [
                    build.SOURCES[source],
                    self.base_timestamps[source],
                    f"`{hashlib.sha256(self.base_raw[source]).hexdigest()}`",
                    license_name,
                    str(counts_a[name]),
                ],
            )

    def test_changing_local_input_updates_rules_lines_and_input_hash_only(self):
        local_a = b"# local static fixture alpha\n198.51.100.0/24\n"
        local_b = b"# local static fixture beta\n198.51.100.0/24\n203.0.113.0/24\n"
        ref_bytes = b"91.108.4.0/22\n"
        ref_ts = "2026-10-01T00:00:05+00:00"

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path_a = root / "custom-alpha.src.txt"
            path_b = root / "custom-beta.src.txt"
            path_a.write_bytes(local_a)
            path_b.write_bytes(local_b)

            counts_a, files_a, actual_a, ref_rows_a = self.run_offline_build(
                root, "local-a", path_a, ref_bytes, ref_ts,
            )
            counts_b, files_b, actual_b, ref_rows_b = self.run_offline_build(
                root, "local-b", path_b, ref_bytes, ref_ts,
            )

            sources_a = files_a["SOURCES.md"].decode("utf-8")
            sources_b = files_b["SOURCES.md"].decode("utf-8")
            self.assertNotIn(str(root), sources_a)
            self.assertNotIn(str(root), sources_b)
            self.assertNotIn(build.STATIC_SOURCE_REPO_PATH, sources_a)
            self.assertNotIn(build.STATIC_SOURCE_REPO_PATH, sources_b)

        self.assertNotEqual(files_a["gfw_static4.txt"], files_b["gfw_static4.txt"])
        self.assertNotIn(b"203.0.113.0/24\n", files_a["gfw_static4.txt"])
        self.assertIn(b"203.0.113.0/24\n", files_b["gfw_static4.txt"])
        self.assertEqual(counts_a["gfw_static4.txt"], 9)
        self.assertEqual(counts_b["gfw_static4.txt"], 10)

        self.assertEqual(
            actual_a["gfw_static4.txt"][0],
            "`custom-alpha.src.txt` (+ built-in `PUBLIC_DNS4`)",
        )
        self.assertEqual(actual_a["gfw_static4.txt"][1], "N/A (local file input)")
        self.assertEqual(actual_a["gfw_static4.txt"][2], f"`{hashlib.sha256(local_a).hexdigest()}`")
        self.assertEqual(actual_a["gfw_static4.txt"][4], "9")

        self.assertEqual(
            actual_b["gfw_static4.txt"][0],
            "`custom-beta.src.txt` (+ built-in `PUBLIC_DNS4`)",
        )
        self.assertEqual(actual_b["gfw_static4.txt"][1], "N/A (local file input)")
        self.assertEqual(actual_b["gfw_static4.txt"][2], f"`{hashlib.sha256(local_b).hexdigest()}`")
        self.assertEqual(actual_b["gfw_static4.txt"][4], "10")
        self.assertNotEqual(actual_a["gfw_static4.txt"][2], actual_b["gfw_static4.txt"][2])

        self.assertEqual(ref_rows_a["gfw_static4.txt"][:3], ref_rows_b["gfw_static4.txt"][:3])
        self.assertEqual(ref_rows_a["gfw_static4.txt"][2], f"`{hashlib.sha256(ref_bytes).hexdigest()}`")
        self.assertIn("`custom-alpha.src.txt`", ref_rows_a["gfw_static4.txt"][3])
        self.assertIn("`custom-beta.src.txt`", ref_rows_b["gfw_static4.txt"][3])
        self.assertNotIn(build.STATIC_SOURCE_REPO_PATH, ref_rows_a["gfw_static4.txt"][3])
        self.assertNotIn(build.STATIC_SOURCE_REPO_PATH, ref_rows_b["gfw_static4.txt"][3])

        for name, (source, license_name) in build.OUTPUT_SOURCES.items():
            self.assertEqual(files_a[name], files_b[name])
            self.assertEqual(actual_a[name], actual_b[name])
            self.assertEqual(
                actual_a[name],
                [
                    build.SOURCES[source],
                    self.base_timestamps[source],
                    f"`{hashlib.sha256(self.base_raw[source]).hexdigest()}`",
                    license_name,
                    str(counts_a[name]),
                ],
            )

    def test_packaged_sources_md_matches_static_input_and_baseline(self):
        root = Path(__file__).resolve().parents[2]
        data_dir = root / "aether-proxy/files/data"
        sources_md = (data_dir / "SOURCES.md").read_text(encoding="utf-8")
        actual, reference = parse_sources_md(sources_md)

        static_src = build.DEFAULT_STATIC_SOURCE_PATH.read_bytes()
        static_sha = f"`{hashlib.sha256(static_src).hexdigest()}`"
        packaged_static = (data_dir / "gfw_static4.txt").read_bytes()
        static_lines = len(packaged_static.decode("utf-8").splitlines())

        with tempfile.TemporaryDirectory() as temp:
            counts, files, _, _ = self.run_offline_build(
                Path(temp), "packaged", build.DEFAULT_STATIC_SOURCE_PATH,
                b"91.108.4.0/22\n", "2026-10-14T09:39:09+00:00",
            )
        self.assertEqual(files["gfw_static4.txt"], packaged_static)
        self.assertEqual(counts["gfw_static4.txt"], 15)
        self.assertEqual(static_lines, 15)

        self.assertEqual(
            actual["gfw_static4.txt"][0],
            f"`{build.STATIC_SOURCE_REPO_PATH}` (+ built-in `PUBLIC_DNS4`)",
        )
        self.assertNotIn(build.SOURCES["telegram-cidr.txt"], actual["gfw_static4.txt"][0])
        self.assertEqual(actual["gfw_static4.txt"][1], "N/A (local repo input)")
        self.assertEqual(actual["gfw_static4.txt"][2], static_sha)
        self.assertEqual(actual["gfw_static4.txt"][4], str(static_lines))

        self.assertEqual(reference["gfw_static4.txt"][0], build.SOURCES["telegram-cidr.txt"])
        self.assertEqual(reference["gfw_static4.txt"][1], "2026-10-14T09:39:09+00:00")
        self.assertEqual(
            reference["gfw_static4.txt"][2],
            "`3ecd072cedf72eceee6961b18a51e37f905d5ce4a656a5d24cf5fea63e6ec651`",
        )
        self.assertIn(f"`{build.STATIC_SOURCE_REPO_PATH}`", reference["gfw_static4.txt"][3])

        for name in build.OUTPUT_SOURCES:
            expected_lines = len((data_dir / name).read_text(encoding="utf-8").splitlines())
            self.assertEqual(actual[name][4], str(expected_lines))


if __name__ == "__main__":
    unittest.main()
