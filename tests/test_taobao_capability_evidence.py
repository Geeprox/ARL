"""Offline checks of the capability claims against the freshly read catalog.

These verify the evidence packet, not an installed App or a shopping workflow.
"""
from pathlib import Path
import hashlib
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]

class TaobaoCapabilityEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads((ROOT / 'docs/TAOBAO-OFFICIAL-CAPABILITIES.json').read_text())
        cls.raw_fixture = (ROOT / cls.evidence['catalog_fixture']).read_bytes()
        cls.tools = json.loads(cls.raw_fixture)
        cls.names = {x['name'] for x in cls.tools}
        cls.claims = {x['capability']: x for x in cls.evidence['capabilities']}

    def test_complete_descriptor_pin_matches_observed_300(self):
        canonical = json.dumps({'tools': sorted(self.tools, key=lambda x: x['name'])}, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()
        self.assertEqual(len(self.tools), 20)
        self.assertEqual(len(self.names), 20)
        self.assertEqual(hashlib.sha256(canonical).hexdigest(), self.evidence['catalog_sha256'])
        self.assertEqual(hashlib.sha256(self.raw_fixture).hexdigest(), self.evidence['catalog_fixture_sha256'])
        self.assertEqual(sorted(self.names), self.evidence['official_tool_names'])

    def test_no_missing_direct_api_is_claimed_as_real(self):
        absent = {'search_products', 'get_product', 'get_product_detail', 'get_product_skus', 'get_cart', 'request_sku_selection', 'get_account_status'}
        self.assertTrue(self.names.isdisjoint(absent))
        for row in self.claims.values():
            if row.get('official_direct_tool'):
                self.assertIn(row['official_direct_tool'], self.names)
        for name in ['product_detail', 'product_specs_SKU', 'product_link', 'cart_read', 'account_status']:
            self.assertIs(self.claims[name]['available_in_qualified_ARL_Mio'], False)

    def test_search_is_a_bounded_page_workflow_and_price_is_not_final(self):
        self.assertTrue({'navigate_to_url', 'get_current_tab', 'read_page_content'}.issubset(self.names))
        self.assertIsNone(self.claims['product_search']['official_direct_tool'])
        self.assertIn('combination', self.claims['product_search']['mechanism'])
        self.assertEqual(self.claims['product_search']['limits']['max_results'], 3)
        self.assertIs(self.claims['price']['final_checkout_price_verified'], False)
        self.assertIs(self.claims['price']['SKU_price_verified'], False)

    def test_present_legacy_cart_is_distinguished_from_qualified_support(self):
        cart = next(x for x in self.tools if x['name'] == 'add_to_cart')
        self.assertIn('旧DOM兼容工具', cart['description'])
        self.assertIn('request_sku_selection', cart['description'])
        self.assertNotIn('request_sku_selection', self.names)
        self.assertIs(self.claims['cart_add']['available_in_qualified_ARL_Mio'], False)
        self.assertEqual(self.claims['cart_add']['real_write_tests'], 0)

    def test_current_primary_sources_and_unperformed_validation_remain_explicit(self):
        sources = self.evidence['sources']
        self.assertEqual(sources['configuration_guide']['status'], 200)
        self.assertEqual(sources['release_300']['status'], 200)
        self.assertEqual(sources['current_public_reference']['status'], 200)
        self.assertTrue(sources['current_public_reference']['instructions_not_executed'])
        self.assertEqual(self.evidence['application']['CFBundleShortVersionString'], '3.0.0')
        for field in ['canonical_writes', 'service_restarts', 'real_business_calls', 'credential_reads']:
            self.assertEqual(self.evidence['this_increment'][field], 0)
        self.assertEqual(self.evidence['this_increment']['installed_ARL_Mio_acceptance'], 'not_run')

    def test_internal_supplier_definitions_do_not_become_external_apis(self):
        boundary = self.evidence['signed_public_program_boundary']
        self.assertTrue(boundary['current_installed_entry_matches'])
        self.assertEqual(boundary['current_installed_entry'], 'out/main/index.js')
        self.assertEqual(boundary['external_registry'], 'Cu()')
        internal = set(boundary['legacy_definitions_not_externally_registered'])
        self.assertEqual(internal, {'search_products', 'get_product_detail'})
        self.assertTrue(internal.isdisjoint(self.names))
        self.assertEqual(boundary['explicitly_filtered_legacy_tool'], 'get_product_skus')
        self.assertNotIn('get_product_skus', self.names)
        self.assertIn('request_sku_selection', boundary['internal_SKU_registry'])
        self.assertNotIn('request_sku_selection', self.names)
        self.assertIn('Cu plus', boundary['code_mode_boundary'])
        observation = self.evidence['external_directory_observation']
        self.assertEqual(observation['source_identity'], 'ARL')
        self.assertEqual(observation['count'], 20)
        self.assertEqual(observation['business_calls'], 0)
        self.assertEqual(observation['login_state'], 'not_checked')

if __name__ == '__main__':
    unittest.main()
