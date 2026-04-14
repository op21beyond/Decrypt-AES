#include "svdpi.h"
#include "Vtb_top_verilator.h"
#include "verilated.h"
#include "verilated_fst_c.h"

#include <cstdint>
#include <memory>

namespace {

constexpr std::uint64_t kHalfPeriodNs   = 5;
constexpr std::uint64_t kResetReleaseNs = 80;   // rst_n=1 at t=80ns (negedge of clk)

svBit g_clk   = 0;
svBit g_rst_n = 0;

}  // namespace

extern "C" svBit tb_dpi_get_clk() {
    return g_clk;
}

extern "C" svBit tb_dpi_get_rst_n() {
    return g_rst_n;
}

int main(int argc, char** argv) {
    VerilatedContext context;
    context.commandArgs(argc, argv);
    context.traceEverOn(true);

    auto top   = std::make_unique<Vtb_top_verilator>(&context);
    auto trace = std::make_unique<VerilatedFstC>();
    top->trace(trace.get(), 99);

    // FST is written under out/ relative to the working directory (TB_DIR).
    // run.sh creates out/ before launching the simulation.
    trace->open("out/dump.fst");

    auto eval_step = [&]() {
        top->eval();
        trace->dump(context.time());
    };

    // Initial evaluation at t=0 to settle reset state
    eval_step();

    while (!context.gotFinish()) {
        // --- Falling edge ---
        g_clk   = 0;
        g_rst_n = (context.time() >= kResetReleaseNs) ? 1 : 0;
        eval_step();
        context.timeInc(kHalfPeriodNs);

        // --- Rising edge ---
        g_clk   = 1;
        g_rst_n = (context.time() >= kResetReleaseNs) ? 1 : 0;
        eval_step();
        context.timeInc(kHalfPeriodNs);
    }

    top->final();
    trace->close();
    return 0;
}
