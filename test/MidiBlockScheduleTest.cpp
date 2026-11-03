#include "MidiBlockSchedule.h"

#include <cstdio>
#include <string>
#include <vector>

namespace {

struct Event {
    int time;
    bool noteOn;
    std::string name;
};

int failures{0};

void expectEqual(const std::string &actual, const std::string &expected, const char *what) {
    if (actual != expected) {
        std::printf("FAIL %s\n  expected: %s\n  actual:   %s\n", what, expected.c_str(), actual.c_str());
        failures++;
    }
}

std::string renderTrace(bool &started, int numSamples, const std::vector<Event> &events) {
    std::string trace;
    auto add = [&trace](const std::string &step) { trace += trace.empty() ? step : " " + step; };
    renderBlockAtEventTimes(
        started, numSamples, events,
        [](const Event &e) { return e.time; },
        [](const Event &e) { return e.noteOn; },
        [&](const Event &e) { add(e.name); },
        [&](int start, int length) { add("render" + std::to_string(start) + "+" + std::to_string(length)); },
        [&](int start, int length) { add("silence" + std::to_string(start) + "+" + std::to_string(length)); });
    return trace;
}

// Synth-relative sample at which each event is applied, for a song cut into host blocks of blockSize.
std::vector<long> appliedAt(const std::vector<Event> &song, int blockSize, int songLength) {
    bool started{false};
    long rendered{0};
    std::vector<long> positions;
    for (int blockStart{0}; blockStart < songLength; blockStart += blockSize) {
        std::vector<Event> block;
        for (const auto &e : song) {
            if (e.time >= blockStart && e.time < blockStart + blockSize) {
                block.push_back({e.time - blockStart, e.noteOn, e.name});
            }
        }
        renderBlockAtEventTimes(
            started, blockSize, block,
            [](const Event &e) { return e.time; },
            [](const Event &e) { return e.noteOn; },
            [&](const Event &) { positions.push_back(rendered); },
            [&](int, int length) { rendered += length; },
            [](int, int) {});
    }
    return positions;
}

std::string join(const std::vector<long> &values) {
    std::string out;
    for (const long v : values) out += (out.empty() ? "" : ",") + std::to_string(v);
    return out;
}

}

int main() {
    {
        bool started{true};
        expectEqual(renderTrace(started, 512, {{0, true, "a"}, {100, false, "b"}, {100, true, "c"}, {300, false, "d"}}),
                    "a render0+100 b c render100+200 d render300+212", "started block splits at every event time");
        expectEqual(renderTrace(started, 512, {}), "render0+512", "started block without events renders whole");
        expectEqual(renderTrace(started, 512, {{511, true, "a"}}), "render0+511 a render511+1", "event on the last sample");
        expectEqual(renderTrace(started, 512, {{-5, true, "a"}, {600, false, "b"}}), "a render0+512 b",
                    "times outside the block are clamped to it");
    }
    {
        bool started{false};
        expectEqual(renderTrace(started, 512, {}), "silence0+512", "fresh synth stays unrendered without events");
        expectEqual(renderTrace(started, 512, {{10, false, "cc"}, {20, false, "vel0"}}), "silence0+512 cc vel0",
                    "events before any note-on are applied without rendering");
        expectEqual(started ? "started" : "fresh", "fresh", "a block without note-on keeps the synth fresh");
        expectEqual(renderTrace(started, 512, {{5, false, "cc"}, {200, true, "n1"}, {300, true, "n2"}}),
                    "silence0+200 cc n1 render200+100 n2 render300+212", "first note-on starts the synth on its sample");
        expectEqual(renderTrace(started, 512, {}), "render0+512", "the next block renders from its start");
    }
    {
        bool started{false};
        expectEqual(renderTrace(started, 512, {{700, true, "n"}}), "silence0+512 n", "note-on past the block end");
        expectEqual(renderTrace(started, 512, {}), "render0+512", "starts rendering the following block");
    }
    {
        const std::vector<Event> song{{3001, false, "cc"}, {4001, true, "n1"}, {4517, false, "off1"}, {9973, true, "n2"},
                                      {9973, false, "cc2"}, {20011, true, "n3"}};
        const std::string expected{join(appliedAt(song, 512, 30000))};
        expectEqual(expected, "0,0,516,5972,5972,16010", "events land on their own sample relative to the first note");
        for (const int blockSize : {64, 333, 1024, 4096}) {
            expectEqual(join(appliedAt(song, blockSize, 30000)), expected, "event positions do not depend on block size");
        }
        std::vector<Event> afterPreRoll{song};
        for (auto &e : afterPreRoll) e.time += 352800;
        expectEqual(join(appliedAt(afterPreRoll, 1024, 400000)), expected, "leading silence does not shift the synth");
    }
    std::printf(failures == 0 ? "OK\n" : "%d FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
