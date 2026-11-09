"""Recording classes (monologue / dialogue / passive): the pure rule, from cases seen in Alan's recordings."""

from omi_notes.recording_class import Voice, classify, effective, speech_seconds


def test_speech_time_is_the_union_of_a_labels_segments_not_their_sum():
    per, total = speech_seconds([{"start": 0, "end": 10, "speaker": "S1", "text": "a"}, {"start": 5, "end": 12, "speaker": "S1", "text": "b"},
                                 {"start": 11, "end": 20, "speaker": "S2", "text": "c"}, {"start": 20, "end": 25, "speaker": "S2", "text": " "}])
    assert per == {"S1": 12, "S2": 9} and total == 20


def test_alan_dictating_is_a_monologue_with_both_cues_agreeing():
    out = classify([Voice("S1", 28.0, score=0.52)], 28.0, interaction="dictation")
    assert out["class"] == "monologue" and out["confidence"] == "high"


def test_dictation_whose_voice_didnt_score_like_alan_is_still_a_monologue_but_low_confidence():
    out = classify([Voice("S1", 37.0, score=-0.43)], 37.0, interaction="dictation")
    assert out["class"] == "monologue" and out["confidence"] == "low"


def test_a_call_with_alan_and_one_other_person_is_a_dialogue():
    out = classify([Voice("S1", 239.0, score=0.05), Voice("S2", 169.0, score=0.80)], 408.0, interaction="call")
    assert out["class"] == "dialogue" and out["confidence"] == "high"


def test_a_video_is_passive_only_when_the_content_says_media_and_no_voice_is_alan():
    voices = [Voice(f"S{k}", s, score=-0.5) for k, s in enumerate([58, 57, 34, 9, 6], 1)]
    out = classify(voices, 164.0, interaction="media")
    assert out["class"] == "passive" and out["confidence"] == "high"
    assert classify(voices, 164.0, interaction=None)["class"] == "dialogue", "the voice alone never proves Alan absent"


def test_media_with_alan_talking_over_it_is_a_dialogue():
    out = classify([Voice("S1", 100, score=-0.5), Voice("S2", 40, score=0.8)], 140, interaction="media")
    assert out["class"] == "dialogue" and out["confidence"] == "low"


def test_a_conversation_where_no_voice_sounds_like_alan_stays_a_dialogue():
    voices = [Voice("S1", 390, score=-0.25), Voice("S4", 302, score=-0.3), Voice("S2", 268, score=-0.22)]
    out = classify(voices, 960.0, interaction="conversation")
    assert out["class"] == "dialogue"


def test_a_noisy_dinner_with_no_clear_voice_and_media_content_is_still_not_passive_if_a_voice_is_unclear():
    voices = [Voice("S3", 1053, score=-0.5), Voice("S1", 999, score=0.04)]
    out = classify(voices, 2052.0, interaction="media")
    assert out["class"] == "passive" and out["confidence"] == "medium", "content says media, one voice unclear"


def test_dictation_with_a_real_second_speaker_is_a_dialogue():
    out = classify([Voice("S1", 60, score=0.8), Voice("S2", 40, score=-0.4)], 100, interaction="dictation")
    assert out["class"] == "dialogue"


def test_a_single_unclear_voice_is_a_monologue_at_low_confidence_whatever_the_content_says():
    out = classify([Voice("S1", 15.0, score=0.12)], 15.0, interaction="conversation")
    assert out["class"] == "monologue" and out["confidence"] == "low"
    assert classify([Voice("S1", 23.0, score=-0.41)], 23.0, interaction="unknown")["class"] == "dialogue", "clearly someone else"


def test_a_monologue_allows_one_short_other_voice():
    assert classify([Voice("S1", 95, score=0.8), Voice("S2", 4, score=-0.5)], 99)["class"] == "monologue"


def test_with_no_evidence_at_all_nothing_changes_from_a_dialogue():
    out = classify([Voice("S1", 60.0, score=None)], 60.0)
    assert out["class"] == "dialogue" and out["confidence"] == "low"


def test_a_named_alan_counts_and_a_named_someone_else_is_never_alan():
    assert classify([Voice("S1", 100, named_wearer=True, score=-0.4)], 100)["class"] == "monologue"
    out = classify([Voice("S1", 100, named_other=True, score=0.9)], 100, interaction="media")
    assert out["class"] == "passive", "assigned to Gigi: not Alan whatever the score says"


def test_no_speech_is_not_classified_as_anything_confident():
    out = classify([], 0.0)
    assert out["class"] == "dialogue" and out["confidence"] == "low"


def test_old_text_only_timing_caps_confidence():
    assert classify([Voice("S1", 28.0, score=0.8)], 28.0, interaction="dictation", coarse_timing=True)["confidence"] == "medium"


def test_the_owners_choice_wins_and_auto_goes_back():
    auto = {"class": "passive", "confidence": "high", "wearer_share": 0.0}
    assert effective(auto, {"class": "monologue", "revision": 2})["class"] == "monologue"
    assert effective(auto, {"class": "auto", "revision": 3})["class"] == "passive"
    assert effective(auto, None) == {"class": "passive", "auto": "passive", "confidence": "high", "overridden": False,
                                     "wearer_share": 0.0, "revision": 0}


def test_any_confirmed_wearer_speech_keeps_media_out_of_passive():
    voices = [Voice("S1", 4.0, named_wearer=True), Voice("S2", 96.0, score=-0.5)]
    out = classify(voices, 100.0, interaction="media")
    assert out["class"] == "dialogue", "Alan said something over the video: not background"
    assert classify([Voice("S1", 4.0, score=0.6), Voice("S2", 96.0, score=-0.5)], 100.0, interaction="media")["class"] == "dialogue"


def test_a_lone_voice_assigned_to_someone_else_is_never_a_monologue_even_when_it_sounds_like_dictation():
    out = classify([Voice("S1", 30.0, named_other=True, person="p-gigi", score=0.1)], 30.0, interaction="dictation")
    assert out["class"] == "dialogue"


def test_overlapping_wearer_labels_are_counted_once():
    voices = [Voice("S1", 60, named_wearer=True, spans=((0, 60),), person="p-alan"),
              Voice("S2", 50, named_wearer=True, spans=((10, 60),), person="p-alan")]  # fmt: skip
    out = classify(voices, 60.0, interaction="dictation")
    assert out["wearer_share"] <= 1.0 and out["wearer_s"] == 60.0
    assert out["class"] == "monologue", "two labels of one person are one voice, not a second speaker"


def test_wearer_union_without_a_person_still_never_exceeds_the_speech():
    voices = [Voice("S1", 60, score=0.8, spans=((0, 60),)), Voice("S2", 50, score=0.7, spans=((10, 60),))]
    assert classify(voices, 60.0)["wearer_share"] == 1.0


def _monologue_prompt(confident: bool) -> str:
    from zoneinfo import ZoneInfo

    from omi_notes.pipeline import prompt

    return prompt.build_user_message(segments=[{"start": 0, "end": 2, "speaker": "S1", "text": "remind me to call"}],
                                     start=0, end=2, tz=ZoneInfo("UTC"), timezone_name="UTC", language="en",
                                     owner_name="Alan", bookmarks=[], provisional=False, audio_gaps=[], now=0,
                                     recording_class="monologue", class_confident=confident)  # fmt: skip


def test_the_summary_is_told_the_owner_is_alone_only_when_that_is_certain():
    assert "The owner is talking alone" in _monologue_prompt(True)
    unsure = _monologue_prompt(False)
    assert "The owner is talking alone" not in unsure and "not confirmed" in unsure
    assert "exempt from the density guidance" in unsure
