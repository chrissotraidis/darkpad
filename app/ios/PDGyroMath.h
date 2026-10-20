// Portable integration rules shared by Core Motion and deterministic tests.
#pragma once
#include <math.h>
#include <stdbool.h>

typedef struct { double timestamp; int landscape; } PDGyroIntegrator;
typedef struct { double yaw, pitch; } PDGyroDelta;

// landscape: +1 = UIInterfaceOrientationLandscapeLeft, -1 = Right, 0 = invalid.
// Core Motion uses portrait device axes. Look degrees are right/down positive.
static inline PDGyroDelta PDGyroStep(PDGyroIntegrator *s, double timestamp,
    double now, double rateX, double rateY, int landscape, bool aiming,
    double sensitivity, bool invert)
{
    PDGyroDelta out = {0, 0};
    if (!aiming || !landscape || !isfinite(timestamp) || !isfinite(now)
        || !isfinite(rateX) || !isfinite(rateY) || !isfinite(sensitivity)
        || timestamp <= 0 || now - timestamp > 0.1 || timestamp > now + 0.01) {
        *s = (PDGyroIntegrator){0};
        return out;
    }
    double dt = timestamp - s->timestamp;
    bool reset = s->timestamp == 0 || s->landscape != landscape || dt < 0 || dt > 0.1;
    s->timestamp = timestamp;
    s->landscape = landscape;
    if (reset || dt == 0) return out;
    sensitivity = fmin(3.0, fmax(0.25, sensitivity));
    // Reject tiny stationary noise; Core Motion supplies bias-corrected rates.
    if (fabs(rateX) < 0.002) rateX = 0;
    if (fabs(rateY) < 0.002) rateY = 0;
    double scale = dt * (180.0 / 3.14159265358979323846) * sensitivity;
    // Bound a single sensor spike without accumulating a delayed turn.
    out.yaw = fmin(12.0, fmax(-12.0, -landscape * rateX * scale));
    out.pitch = fmin(12.0, fmax(-12.0, landscape * rateY * scale * (invert ? -1 : 1)));
    return out;
}
