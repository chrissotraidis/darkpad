#include "../app/ios/PDGyroMath.h"
#include <assert.h>
#include <stdio.h>
static void near(double actual, double expected) { assert(fabs(actual - expected) < 1e-7); }
static void zero(PDGyroDelta d) { near(d.yaw, 0); near(d.pitch, 0); }
int main(void)
{
    // A one-second, 90-degree rotation must not depend on sample/frame rate.
    const double rate = 3.14159265358979323846 / 2;
    for (int hz = 30; hz <= 120; hz += 30) {
        PDGyroIntegrator s = {0}; double yaw = 0;
        for (int i = 0; i <= hz; i++) {
            double t = 10 + (double)i / hz;
            PDGyroDelta d = PDGyroStep(&s,t,t,rate,0,1,true,1,false);
            yaw += d.yaw;
            // Polling the same sample again must never double-count motion.
            zero(PDGyroStep(&s,t,t,rate,0,1,true,1,false));
        }
        near(yaw,-90);
    }
    PDGyroIntegrator s = {0};
    zero(PDGyroStep(&s,1,1,1,1,1,true,1,false));
    PDGyroDelta left = PDGyroStep(&s,1.01,1.01,1,1,1,true,1,false);
    zero(PDGyroStep(&s,1.02,1.02,1,1,-1,true,1,false)); // rotation reanchors
    PDGyroDelta right = PDGyroStep(&s,1.03,1.03,1,1,-1,true,1,false);
    near(left.yaw,-right.yaw); near(left.pitch,-right.pitch);
    PDGyroDelta inv = PDGyroStep(&s,1.04,1.04,1,1,-1,true,2,true);
    near(inv.yaw,2*right.yaw); near(inv.pitch,-2*right.pitch);
    zero(PDGyroStep(&s,1.05,1.05,1,1,-1,false,1,false)); // aim release
    zero(PDGyroStep(&s,2,2,1,1,-1,true,1,false)); // no accumulated turn
    zero(PDGyroStep(&s,3,3,1,1,-1,true,1,false)); // suspend/gap
    zero(PDGyroStep(&s,3.01,4,1,1,-1,true,1,false)); // stale sensor
    zero(PDGyroStep(&s,4,4,NAN,1,-1,true,1,false));
    zero(PDGyroStep(&s,4,4,1,1,0,true,1,false)); // invalid orientation
    zero(PDGyroStep(&s,4,4,0,0,1,true,1,false));
    zero(PDGyroStep(&s,4.01,4.01,0.001,-0.001,1,true,1,false)); // resting noise
    puts("gyro integration: cadence, duplicate samples, orientation, inversion, sensitivity, release, gaps, stale/invalid input PASS");
}
