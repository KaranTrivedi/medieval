# ui_panel.gd
# Slim CanvasLayer host for all modal panels (CharacterPanel, RegionPanel,
# CourtPanel, FamilyTreePanel, etc.). Previously rendered the right-side
# InfoPanel from per-tier data dicts — that panel was removed in favour of a
# rich hover tooltip + direct click-to-RegionPanel in CampaignMap.gd. The
# script is kept so the existing .tscn keeps a valid script reference, but
# carries no state and exposes no API.
extends CanvasLayer
