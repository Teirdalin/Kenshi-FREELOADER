#include "../src/StreamingPolicy.h"
#include <stdio.h>
#include <limits>

static int checks = 0, failures = 0;
static void check(bool ok, const char* name) {
    ++checks;
    if (!ok) { ++failures; printf("FAIL: %s\n", name); }
}

int main() {
    using namespace freeloader;
    check(sectorAt(0, 0) == Sector(32, 32), "origin");
    check(sectorAt(-0.1, -0.1) == Sector(31, 31), "negative coordinates floor");
    check(sectorAt(-147456, -147456) == Sector(0, 0), "world lower edge");
    check(sectorAt(147455.9, 147455.9) == Sector(63, 63), "world upper edge");
    check(!sectorAt(147456, 0).valid(), "outside upper edge");
    check(!sectorAt(-147456.1, 0).valid(), "outside lower edge");
    check(!sectorAt(std::numeric_limits<double>::quiet_NaN(), 0).valid(), "NaN rejected");
    check(!sectorAt(0, std::numeric_limits<double>::infinity()).valid(), "infinity rejected");
    Predictor predictor;
    check(predictor.update(1000, 2304, 0, 1800).count == 0, "first sample");
    check(predictor.update(1100, 2304, 100, 1800).count == 0, "sampling throttle");
    check(predictor.update(1100, 2304, 250, 1800).count == 0, "settle period");
    Candidates c;
    for (unsigned int t = 500; t <= 2000; t += 250)
        c = predictor.update(1000 + t * 0.4, 2304, t, 1800);
    check(c.count == 9, "moving prediction");
    check(c.contains(Sector(34, 32)), "east approach preloads next strip before camera recenter");
    check(!c.contains(Sector(31, 32)), "east prediction drops rear strip");
    c = predictor.update(1700, 2304, 2250, 1800);
    check(c.contains(Sector(30, 32)), "direction reversal recomputes target");
    check(predictor.update(1700, 2304, 2500, 1800).count == 0, "stationary does not request");
    check(predictor.update(50000, 50000, 2750, 1800).count == 0, "squad jump rejected");
    check(predictor.update(50100, 50000, 3000, 1800).count == 0, "jump settling");
    check(predictor.update(50200, 50000, 7000, 1800).count == 0, "long gap rejected");
    predictor.reset();
    check(predictor.update(0, 0, 7250, 1800).count == 0, "reset has no retained direction");
    // Repeated boundary travel checks include diagonal approaches and clock wrap.
    for (int x = 0; x < 64; ++x) for (int z = 0; z < 64; ++z) {
        Predictor p;
        unsigned int start = 0xfffffe00u;
        double px = (x - 31.5) * SectorSize, pz = (z - 31.5) * SectorSize;
        for (unsigned int t = 0; t <= 1500; t += 250)
            c = p.update(px + t * 0.1, pz + t * 0.1, start + t, 3500);
        check(c.count >= 4 && c.count <= 9, "bounded world-edge prediction with wrapped clock");
        for (int i = 0; i < c.count; ++i) {
            check(c.sectors[i].valid(), "candidate coordinate in world");
            for (int j = 0; j < i; ++j)
                check(!(c.sectors[i] == c.sectors[j]), "candidate unique");
        }
    }
    printf("Streaming policy: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
