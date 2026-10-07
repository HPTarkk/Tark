#include "../src/spectral_suppressor.h"
#include <cmath>
#include <cstdio>
#include <vector>

int main() {
  SpectralSuppressor s(16000);
  std::vector<double> input(1600), bypass(1600), wet(1600);
  for (size_t i=0;i<input.size();++i)
    input[i]=0.05*std::sin(2.0*3.14159265358979323846*1000.0*i/16000.0);
  s.setStrength(0.0); s.process(input.data(),input.size(),bypass.data());
  for(size_t i=0;i<input.size();++i)
    if(std::fabs(input[i]-bypass[i])>1e-15) return 1;
  s.reset(); s.setStrength(0.8); s.process(input.data(),input.size(),wet.data());
  for(double v:wet) if(!std::isfinite(v)) return 2;
  std::printf("All spectral suppressor tests passed.\n");
  return 0;
}
