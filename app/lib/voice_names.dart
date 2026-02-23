/// Human-friendly display names for builtin voices.
/// Key = file stem (e.g. "cosette"), value = display name.
const voiceDisplayNames = <String, String>{
  // Original Pocket TTS voices
  'cosette': 'Cosette Valjean',
  'marius': 'Marius Pontmercy',

  // Alba McKenna dataset
  'alba_announcer': 'Alba · Announcer',
  'alba_casual': 'Alba · Casual',
  'alba_merchant': 'Alba · Merchant',

  // Unmute voices
  'unmute_default': 'Sophie Laurent',
  'unmute_developer': 'Thomas Berger',
  'unmute_developpeuse': 'Claire Dubois',
  'unmute_fabien': 'Fabien Moreau',
  'unmute_p329': 'Nadia Petit',

  // VCTK corpus (British English)
  'vctk_p225_f': 'Emma Collins',
  'vctk_p226_m': 'James Mitchell',
  'vctk_p228_f': 'Olivia Bennett',
  'vctk_p231_f': 'Sarah Parker',
  'vctk_p232_m': 'Daniel Cooper',
  'vctk_p236_f': 'Hannah Brooks',
  'vctk_p239_f': 'Lucy Morgan',
  'vctk_p243_m': 'William Foster',
  'vctk_p245_m': 'Oliver Hayes',
  'vctk_p250_f': 'Grace Sullivan',
  'vctk_p251_m': 'Henry Clarke',
  'vctk_p252_m': 'George Turner',
  'vctk_p257_f': 'Amelia Reed',
  'vctk_p259_m': 'Arthur Walsh',
  'vctk_p264_f': 'Charlotte Price',
  'vctk_p270_m': 'Edward Hughes',
  'vctk_p272_m': 'Robert Ellis',
  'vctk_p276_f': 'Isabella Grant',
  'vctk_p278_m': 'Samuel Dixon',
  'vctk_p286_m': 'Benjamin Ward',
  'vctk_p294_f': 'Victoria Stone',
  'vctk_p304_m': 'Alexander Ross',
};

/// Resolve a voice file stem to a nice display name.
/// Falls back to capitalizing the raw name if not in the map.
String voiceDisplayName(String stem) {
  return voiceDisplayNames[stem] ??
      stem.split('_').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
}
