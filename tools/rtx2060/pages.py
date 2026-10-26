#!/usr/bin/env python3
"""pages.py scroll OUT.html | video OUT.html CLIP - local pages for the Safari scenarios, so nothing is fetched.
scroll: a long page of text, gradients and shadows, the kind of layers Safari scrolling composites.
video:  CLIP looping, muted, full width. Safari blocks the autoplay of a page opened by AppleScript, and leaves
        getVideoPlaybackQuality() at 0 outside MSE, so the harness calls window.nvstart() (play() plus a
        requestVideoFrameCallback counter) and reads window.nvq(). Frame callbacks fire only while the window is visible."""
import html, sys

def scroll(out):
    blocks = []
    for i in range(400):
        hue = (i * 37) % 360
        blocks.append(f'<div class="b" style="background:linear-gradient(135deg,hsl({hue},70%,60%),hsl({(hue + 90) % 360},70%,40%))">'
                      f'<h2>Section {i}</h2><p>{"Lorem ipsum dolor sit amet, consectetur adipiscing elit. " * 12}</p></div>')
    open(out, 'w').write('<!doctype html><meta charset="utf-8"><title>rtx2060 scroll</title><style>'
                         'body{font:16px -apple-system;margin:0 auto;max-width:1400px}'
                         '.b{margin:24px;padding:24px;border-radius:16px;box-shadow:0 8px 24px rgba(0,0,0,.35);color:#fff}'
                         '</style>' + ''.join(blocks))

def video(out, clip):
    open(out, 'w').write('<!doctype html><meta charset="utf-8"><title>rtx2060 video</title>'
                         '<body style="margin:0;background:#000">'
                         f'<video id="v" src="file://{html.escape(clip)}" muted loop playsinline style="width:100%"></video>'
                         '<script>var v=document.getElementById("v"),r={play:"not started",n:0,first:null,last:null,t0:null,prev:null,maxgap:0,gaps:[]};'
                         'function cb(now,m){if(r.first===null){r.first=m;r.t0=now}else{var g=now-r.prev;r.gaps.push(g);if(g>r.maxgap)r.maxgap=g}'
                         'r.prev=now;r.last=m;r.n++;v.requestVideoFrameCallback(cb)}'
                         'window.nvstart=function(){if(r.play!=="not started")return "started";r.play="pending";v.requestVideoFrameCallback(cb);'
                         'v.play().then(function(){r.play="ok"},function(e){r.play=e.name+": "+e.message});return "started"};'
                         # gaps_over_2: callbacks further apart than two content frames (33.3 ms for a 60 fps clip), +1 ms for Safari's
                         # rounding of callback times
                         'window.nvq=function(){var q=v.getVideoPlaybackQuality(),f=r.first,l=r.last,'
                         'ms=f&&l?l.mediaTime-f.mediaTime:0,pf=f&&l?l.presentedFrames-f.presentedFrames:0,lim=pf>0?2000*ms/pf+1:0;'
                         'return {play:r.play,callbacks:r.n,presented:pf,media_s:ms,wall_s:f?(r.prev-r.t0)/1000:0,max_gap_ms:r.maxgap,'
                         'gaps_over_2:r.gaps.filter(function(g){return g>lim}).length,visibility:document.visibilityState,'
                         'total:q.totalVideoFrames,dropped:q.droppedVideoFrames,'
                         'time:v.currentTime,paused:v.paused,error:v.error?v.error.code:null,width:v.videoWidth,height:v.videoHeight}}'
                         '</script>')

if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'scroll': scroll(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == 'video': video(sys.argv[2], sys.argv[3])
    else: sys.exit(__doc__)
