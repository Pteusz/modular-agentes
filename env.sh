# source /opt/modular-agentes/env.sh
T=/opt/modular-agentes/.tools
export PATH=$T/otp/bin:$T/elixir/bin:$PATH MIX_HOME=$T/mix HEX_HOME=$T/hex
export RUSTUP_HOME=$T/rustup CARGO_HOME=$T/cargo
export PATH=$T/cargo/bin:$PATH
