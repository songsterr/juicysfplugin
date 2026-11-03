#pragma once

#include <algorithm>

// Splits the block at each MIDI event so events land on their own sample (to fluidsynth's 64-sample grid), whatever the host block size.
// Nothing renders before the first note-on: reverb and chorus modulate through silence, so host setup, pre-roll or warm-up would change the output.
template <typename Events, typename TimeOf, typename IsNoteOn, typename Apply, typename Render, typename Silence>
void renderBlockAtEventTimes(bool &started, int numSamples, const Events &events,
                             TimeOf timeOf, IsNoteOn isNoteOn, Apply apply, Render render, Silence silence) {
    int pos{0};
    if (!started) {
        for (const auto &event : events) {
            if (isNoteOn(event)) {
                started = true;
                pos = std::clamp(timeOf(event), 0, numSamples);
                break;
            }
        }
        if (!started) {
            pos = numSamples;
        }
        silence(0, pos);
    }
    for (const auto &event : events) {
        const int time{std::clamp(timeOf(event), 0, numSamples)};
        if (started && time > pos) {
            render(pos, time - pos);
            pos = time;
        }
        apply(event);
    }
    if (started && pos < numSamples) {
        render(pos, numSamples - pos);
    }
}
