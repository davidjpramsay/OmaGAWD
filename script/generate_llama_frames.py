#!/usr/bin/python3
"""Render Mac DancingLlamaView.swift's poses using its shared SVG glyph.

Ported from macOS 85070c8. Cairo + librsvg are generation-only;
the installed player displays a pre-rendered atlas without these dependencies.
"""
import math
from pathlib import Path
import cairo
import gi
gi.require_version('Rsvg', '2.0')
from gi.repository import Rsvg

ROOT = Path(__file__).resolve().parents[1]
SIZE = (120, 102)  # Mac 40 x 34 points at 3x.
COUNT = 50
DANCES = 4


def ease(value):
    value = min(1, max(0, value))
    return value * value * (3 - 2 * value)


def phase(dance, frame):
    p = frame / COUNT * 2 * math.pi
    second, first = ((.10, .04), (.07, -.04), (.08, .03), (.08, -.03))[dance]
    return p + second * math.sin(2*p) + first * math.sin(p)


def head_bang(p):
    beats = p / (2 * math.pi) * 4
    progress = beats - math.floor(beats)
    dip = ease(progress/.28) if progress < .28 else 1-ease((progress-.28)/.58) if progress < .86 else 0
    return -.16 + dip, dip


def twerk_motion(p):
    pop = (1-math.cos(4*p))/2
    transform = cairo.Matrix()
    transform.translate(455,490)
    transform.rotate(-.18+.64*pop)
    transform.scale(1+.055*math.sin(2*p),1-.08*pop)
    transform.translate(-455,-490)
    return transform, pop


def bounce(p):
    beats = p / (2 * math.pi) * 4
    progress = beats - math.floor(beats)
    lift = ease(progress / .22) if progress < .22 else 1 - ease((progress-.22)/.40) if progress < .62 else 0
    compression = math.sin(math.pi * max(0, (progress-.62)/.38))**2
    height = 105 if int(math.floor(beats)) % 2 == 0 else 78
    return height * lift - 12 * compression, lift, compression


def leg(ctx, hip, step, near, dance, planted_foot=None):
    progress = step % 1
    foot_y, knee_y = 188, hip[1] - 132
    if dance == 0:
        if progress < .19:
            lift = ease(progress/.19); foot_x = 90 - 145*lift
        elif progress < .29:
            lift = 1; foot_x = -55
        elif progress < .48:
            plant = ease((progress-.29)/.19); lift = 1-plant; foot_x = -55-60*plant
        else:
            lift = 0; foot_x = -115 + 205*ease((progress-.48)/.52)
        knee_x = -145*lift + foot_x*.3*(1-lift)
        knee_y += 108*lift + 32*bounce(progress*2*math.pi)[2]
        foot_y += 140*lift
    elif dance == 1:
        sway = math.sin(progress*2*math.pi)
        lift = max(0, math.sin(progress*4*math.pi))**2
        foot_x = 130*sway; knee_x = 60*sway - 35*lift
        knee_y += 45*lift; foot_y += 44*lift
    elif dance == 2:
        dip = head_bang(step*2*math.pi)[1]
        foot_x = 8 if near else -8
        knee_x = -22*dip; knee_y -= 18*dip
    else:
        pop = twerk_motion(step*2*math.pi)[1]
        rear = hip[0] > 550
        knee_x = -65-35*pop if rear else 25
        foot_x = 0
        knee_y = (hip[1]+foot_y)/2 - (24+18*pop if rear else 0)
    knee, foot = (hip[0]+knee_x, knee_y), planted_foot or (hip[0]+foot_x, foot_y)
    cream = (.85,.81,.64) if near else (.64,.62,.48)
    highlight = (.95,.90,.74) if near else (.76,.73,.57)
    ctx.set_line_cap(cairo.LINE_CAP_ROUND); ctx.set_line_join(cairo.LINE_JOIN_ROUND)
    ctx.set_source_rgb(*cream); ctx.set_line_width(62 if near else 48)
    ctx.move_to(*hip)
    # Cairo's cubic equivalent of the Mac quadratic hip-to-knee path.
    control = (hip[0]+12, (hip[1]+knee[1])/2)
    ctx.curve_to(hip[0]+2/3*(control[0]-hip[0]), hip[1]+2/3*(control[1]-hip[1]),
                 knee[0]+2/3*(control[0]-knee[0]), knee[1]+2/3*(control[1]-knee[1]), *knee)
    ctx.stroke()
    ctx.set_source_rgb(*highlight); ctx.set_line_width(38 if near else 26)
    ctx.move_to(hip[0]-5, hip[1]); ctx.line_to(knee[0]-5,knee[1]); ctx.stroke()
    ctx.set_source_rgb(*cream); ctx.set_line_width(26 if near else 20)
    ctx.move_to(*knee); ctx.line_to(*foot); ctx.stroke()
    ctx.set_source_rgb(.42,.40,.30)
    ctx.move_to(foot[0]-26,foot[1]-12); ctx.line_to(foot[0]-9,foot[1]+7)
    ctx.line_to(foot[0]+13,foot[1]+6); ctx.line_to(foot[0]+16,foot[1]-12)
    ctx.close_path(); ctx.fill()


def body_mask(ctx):
    ctx.move_to(0,1024); ctx.line_to(1024,1024); ctx.line_to(1024,480); ctx.line_to(782,480)
    ctx.curve_to(765,389,690,416,602,408); ctx.curve_to(525,380,449,385,389,414)
    ctx.curve_to(329,415,297,459,278,520); ctx.line_to(0,520); ctx.close_path()


def head_mask(ctx, base):
    ctx.move_to(0,1024); ctx.line_to(470,1024); ctx.line_to(470,700)
    ctx.curve_to(388,700,390,640,394,600)
    ctx.line_to(394,base); ctx.line_to(0,base); ctx.close_path()


def draw_glyph(ctx, glyph):
    ctx.save()
    # The traced SVG has the same 599x731 painted bounds as the original glyph.
    ctx.translate(202,905); ctx.scale(1,-1)
    bounds = Rsvg.Rectangle()
    bounds.x, bounds.y, bounds.width, bounds.height = 0, 0, 599, 731
    glyph.render_document(ctx, bounds)
    ctx.restore()


def draw_twerk(ctx, glyph, p):
    transform, _ = twerk_motion(p)
    step = p/(2*math.pi)
    for hip, near, rear in [((470,438),False,False), ((641,438),False,True),
                           ((424,446),True,False), ((709,447),True,True)]:
        leg(ctx, transform.transform_point(*hip) if rear else hip, step, near, 3,
            planted_foot=(hip[0]+(10 if near else -10),188))
    ctx.save(); ctx.transform(transform)
    body_mask(ctx); ctx.clip()
    ctx.rectangle(425,0,599,1024); ctx.clip()
    draw_glyph(ctx,glyph); ctx.restore()
    # Same shoulder overlap as Mac: keep the head/front still while the rump pops.
    ctx.save(); body_mask(ctx); ctx.clip()
    ctx.rectangle(0,0,510,1024); ctx.clip()
    draw_glyph(ctx,glyph); ctx.restore()


def render(ctx, glyph, dance=None, p=0):
    ctx.save(); ctx.scale(3,3)
    scale = 24 / 731
    # Mirror AppKit's upward Y axis into the Qt image's downward Y axis.
    ctx.translate(0,34); ctx.scale(1,-1)
    ctx.translate((40-599*scale)/2-202*scale, (34-731*scale)/2-174*scale-1)
    ctx.scale(scale,scale)
    if dance == 3:
        draw_twerk(ctx,glyph,p)
        ctx.restore()
        return
    if dance is not None:
        side = math.sin(p)
        if dance == 0:
            height,lift,compression = bounce(p)
            shift = (35*side,height); rotation = .09*side
            stretch = (1+.035*compression,1+.02*lift-.065*compression)
        elif dance == 1:
            shift = (100*side,32*math.sin(p*2)**2); rotation = -.12*side
            stretch = (1,1-.045*side*side)
        else:
            shift = (0,0); rotation = 0; stretch = (1,1)
        ctx.translate(512+shift[0],420+shift[1]); ctx.rotate(rotation); ctx.scale(*stretch); ctx.translate(-512,-420)
        step = p/(2*math.pi)
        leg(ctx,(470,438),step+.5,False,dance)
        leg(ctx,(641,438),step+(0 if dance==0 else .5),False,dance)
        leg(ctx,(424,446),step,True,dance)
        leg(ctx,(709,447),step+(0 if dance==1 else .5),True,dance)
        if dance == 2:
            ctx.save(); ctx.translate(365,545); ctx.rotate(head_bang(p)[0]); ctx.translate(-365,-545)
            head_mask(ctx,505); ctx.clip(); draw_glyph(ctx,glyph); ctx.restore()
        body_mask(ctx); ctx.clip()
        if dance == 2:
            ctx.rectangle(0,0,1024,1024); head_mask(ctx,548)
            ctx.set_fill_rule(cairo.FILL_RULE_EVEN_ODD); ctx.clip()
    draw_glyph(ctx,glyph)
    ctx.restore()


def main():
    glyph = Rsvg.Handle.new_from_file(str(ROOT/'assets/llama.svg'))
    sheet = cairo.ImageSurface(cairo.FORMAT_ARGB32, SIZE[0]*10, SIZE[1]*(COUNT*DANCES//10))
    ctx = cairo.Context(sheet)
    for dance in range(DANCES):
        for frame in range(COUNT):
            index = dance*COUNT+frame
            ctx.save(); ctx.translate(index%10*SIZE[0],index//10*SIZE[1]); ctx.rectangle(0,0,*SIZE); ctx.clip(); render(ctx,glyph,dance,phase(dance,frame)); ctx.restore()
    sheet.write_to_png(str(ROOT/'assets/llama-dances.png'))
    standing = cairo.ImageSurface(cairo.FORMAT_ARGB32,*SIZE)
    render(cairo.Context(standing),glyph)
    standing.write_to_png(str(ROOT/'assets/llama-standing.png'))


if __name__ == '__main__': main()
