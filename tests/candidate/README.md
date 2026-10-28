# Retired candidate tests

These tests belong to DarkPad's earlier networking experiment on the
intermediate engine commit 3ee8ed0 (overlay/network-candidate, protocol
0x4431). They run only against that reconstructed source:

    scripts/audit-upstream.sh 3ee8ed0cd549b64350848655c43ae1568e449c6d overlay/network-candidate
    python3 tests/candidate/<test>.py work/upstream-audit.<id>/src[/file]

The shipping engine (Dab's Mod v3.15.1) replaced what they cover:

- candidate_network_commands / candidate_network_motion: the 0x4431 touch
  fields. Shipping overlay 0089 sends touch look inside protocol 33's mdx/mdy;
  see tests/network_touch_look.py.
- direct_session_cancel: DarkPad's Direct LAN dialog. Upstream v3.15.1 has its
  own LAN and Direct Connect pages.
- network_menu_state / network_player_position / network_shell_player: the
  local-player reads, now rebelancap's 0084 plus DarkPad 0090; see
  tests/network_local_player.py.
- candidate_audio_channels: the 6-channel resampler merge. The shipping 0023
  forces two output channels on iOS, so surround plays as Dolby Surround.
