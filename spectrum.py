"""Log-spaced filter-bank spectrum on an analysis-only branch of mpv audio."""
import math

FREQUENCIES = [50 * (16000 / 50) ** (i / 15) for i in range(16)]


def filter_graph(path):
    # Playback bypasses the analysis graph, preserving its channels and samples.
    graph = ['[in]asplit=2[out][analysis]',
             '[analysis]aresample=48000,aformat=sample_fmts=flt:channel_layouts=mono,asplit=16' + ''.join(f'[b{i}]' for i in range(16))]
    for i, frequency in enumerate(FREQUENCIES):
        graph.append(f'[b{i}]bandpass=f={frequency:.3f}:t=o:w=0.55,aformat=channel_layouts=mono[f{i}]')
    graph.append(''.join(f'[f{i}]' for i in range(16)) +
                 'amerge=inputs=16,astats=metadata=1:reset=1:measure_perchannel=RMS_level:measure_overall=none,' +
                 f'ametadata=mode=print:file={path}:direct=1,anullsink')
    return ';'.join(graph)


def level(db):
    try:
        value = float(db)
        return max(0.0, min(1.0, (value + 60) / 60)) if math.isfinite(value) else 0.0
    except (ValueError, TypeError):
        return 0.0
