.pragma library

// Timing port of macOS LlamaDanceClock / LlamaDance (7a8d03c).
function create() { return {elapsed: 0, playingSince: null} }
function update(clock, playing, stopped, now) {
    if (stopped) return create()
    if (playing) return {elapsed: clock.elapsed, playingSince: clock.playingSince === null ? now : clock.playingSince}
    return {elapsed: clock.elapsed + (clock.playingSince === null ? 0 : Math.max(0, now - clock.playingSince)), playingSince: null}
}
function sample(clock, now) {
    const position = clock.elapsed + (clock.playingSince === null ? 0 : Math.max(0, now - clock.playingSince))
    const dance = Math.floor(position / 10) % 2
    const frame = Math.min(49, Math.floor(((position % 10) % (5 / 3)) / (5 / 3) * 50))
    return {dance: dance, frame: frame}
}
