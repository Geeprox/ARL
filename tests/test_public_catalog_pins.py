"""The private owner keeps exact fixed schema anchors across metadata changes."""
import hashlib
import json
from pathlib import Path
import re
import unittest

ROOT=Path(__file__).resolve().parents[1]

class PublicCatalogPins(unittest.TestCase):
 def test_fixed_travel_and_music_anchors_match_the_reviewed_static_catalog(self):
  source=(ROOT/'integrations/mio_apple/MioReadCatalog.swift').read_text()
  tools,_=json.JSONDecoder().raw_decode(source[source.index('[{'):])
  consumer=(ROOT/'integrations/mio_apple/Consumer.swift').read_text()
  anchors=re.findall(r'digest\(try jsonBytes\(Array\(tools\.(?:prefix\(14\)|suffix\(6\))\)\)\)=="([0-9a-f]{64})"',consumer)
  self.assertEqual(len(anchors),2)
  for rows,anchor in zip((tools[:14],tools[14:20]),anchors):
   self.assertEqual(hashlib.sha256(json.dumps(rows,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()).hexdigest(),anchor)
  self.assertEqual(tools[:14],json.loads((ROOT/'docs/mio-tools.json').read_text())['tools'])
