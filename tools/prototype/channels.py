"""Check candidate channel feeds (YouTube's public RSS) and print each channel's title."""
import urllib.request, xml.etree.ElementTree as ET, concurrent.futures as cf, json, sys
NS = {"a": "http://www.w3.org/2005/Atom", "m": "http://search.yahoo.com/mrss/", "yt": "http://www.youtube.com/xml/schemas/2015"}
IDS = """UCSHZKyawb77ixDdsGog4iWA UCYO_jab_esuFRV4b17AJtAw UCbfYPyITQ-7l4upoX8nvctg UCsXVk37bltHxD1rDPwtNM8Q UCXUPKJO5MZQN11PqgIvyuvQ
UCcefcZRL2oaA_uBNeo5UOWg UCP7jMXSY2xbc3KCAE0MHQ-A UCXl4i9dYBrFOabk0xGmbkRA UCMLtBahI5DMrt0NPvDSoIRQ UCZ4AMrDcNrfy3X6nsU8-rPg
UC7IcJI8PUf5Z3zKxnZvTBog UCX6b17PVsYBQ0ip5gyeme-Q UCLXo7UDZvByw2ixzpQCufnA UCHuiy8bXnmK5nisYHUd1J5g UC6t1O76G0jYXOAoYCm153dA
UCNAxrHudMfdzNi6NxruKPLw UCAuUUnT6oDeKwE6v1NGQxug UCvQECJukTDE2i6aCoMnS-Vg UC2D2CMWXMOVWx7giW1n3LIg UCHnyfMqiRRG1u-2MsSQLbXA
UCsBjURrPoezykLs9EqgamOA UCbRP3c757lWg9M-U7TyEkXA UC9-y-6csu5WGm29I7JiwpnA UCrM7B7SL_g1edFOnmj-SDKg UCLB7AzTwc6VFZrBsO2ucBMg""".split()
def feed(cid):
    try:
        x = urllib.request.urlopen(f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}", timeout=20).read()
        root = ET.fromstring(x)
        entries = root.findall("a:entry", NS)
        return cid, root.findtext("a:title", namespaces=NS), len(entries)
    except Exception as e:
        return cid, None, str(e)[:60]
with cf.ThreadPoolExecutor(8) as ex:
    for cid, title, n in ex.map(feed, IDS): print(cid, "|", title, "|", n)
