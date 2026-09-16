#pragma once
#include <math.h>

namespace freeloader {
const double SectorSize = 4608.0;
const int GridSize = 64;
const int MaxLeases = 6;

struct Sector {
    int x, z;
    Sector(int a = -1, int b = -1) : x(a), z(b) {}
    bool valid() const { return x >= 0 && x < GridSize && z >= 0 && z < GridSize; }
    bool operator==(const Sector& b) const { return x == b.x && z == b.z; }
};

inline bool finitePosition(double x, double z) {
    const double edge = SectorSize * 32.0;
    return x >= -edge && x < edge && z >= -edge && z < edge;
}
inline Sector sectorAt(double x, double z) {
    if (!finitePosition(x, z)) return Sector();
    return Sector(static_cast<int>(floor(x / SectorSize + 32.0)),
                  static_cast<int>(floor(z / SectorSize + 32.0)));
}

struct Candidates {
    Sector sectors[9];
    int count;
    Candidates() : count(0) {}
    bool contains(const Sector& s) const {
        for (int i = 0; i < count; ++i) if (sectors[i] == s) return true;
        return false;
    }
};

class Predictor {
    bool sampled;
    double x, z;
    unsigned int stamp, settled;
public:
    Predictor() { reset(); }
    void reset() { sampled = false; x = z = 0; stamp = settled = 0; }

    Candidates update(double px, double pz, unsigned int now, double lead) {
        Candidates out;
        if (!finitePosition(px, pz)) { reset(); return out; }
        if (!sampled) {
            sampled = true; x = px; z = pz; stamp = settled = now;
            return out;
        }
        unsigned int elapsed = now - stamp;
        if (elapsed < 250) return out;
        double dx = px - x, dz = pz - z;
        double distance = sqrt(dx * dx + dz * dz);
        x = px; z = pz; stamp = now;
        // Squad jumps and long gaps cannot provide a useful travel direction.
        if (elapsed > 2000 || distance > 512.0) { settled = now; return out; }
        if (now - settled < 1000 || distance < elapsed * 0.002) return out;
        double speed = distance * 1000.0 / elapsed;
        double reach = lead + speed * 10.0;
        if (reach > 4000.0) reach = 4000.0;
        if (reach < 500.0) reach = 500.0;
        const double edge = SectorSize * 32.0;
        double tx = px + dx / distance * reach;
        double tz = pz + dz / distance * reach;
        if (tx < -edge) tx = -edge;
        if (tz < -edge) tz = -edge;
        if (tx >= edge) tx = edge - 1.0;
        if (tz >= edge) tz = edge - 1.0;
        Sector center = sectorAt(tx, tz);
        double scores[9];
        for (int a = -1; a <= 1; ++a) for (int b = -1; b <= 1; ++b) {
            Sector s(center.x + a, center.z + b);
            if (!s.valid()) continue;
            double sx = (s.x - 31.5) * SectorSize - px;
            double sz = (s.z - 31.5) * SectorSize - pz;
            double score = sx * sx + sz * sz;
            int i = out.count++;
            while (i > 0 && scores[i - 1] > score) {
                scores[i] = scores[i - 1]; out.sectors[i] = out.sectors[i - 1]; --i;
            }
            scores[i] = score; out.sectors[i] = s;
        }
        return out;
    }
};
}
