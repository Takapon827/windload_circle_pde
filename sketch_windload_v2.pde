//更新:2026/05/08
//LiDARデータ受信はTouch DesignerよりOSCで行うことを推奨する。(HOKUYO CHOP)
//本コードはM5stack(DCモーター9ch制御)へUDP経由で制御信号を送信している。(255段階)

import oscP5.*;
import netP5.*;
import java.util.*;

OscP5 oscP5;

// ====== CONFIG ======
final int   OSC_IN_PORT  = 9000;
final float OUTPUT_W     = 1920;
final float OUTPUT_H     = 1080;
final int   TIMEOUT_MS   = 300;

final boolean DROP_LAST_POINT  = true;
final boolean SHOW_POINT_INDEX = false;

final boolean SEND_TO_MAX = true;
final String  MAX_HOST    = "192.168.xx.xx";
final int     MAX_PORT    = 9100;
NetAddress maxAddr;

final String ADDR_TOUCHES  = "/touches";
final String ADDR_LASER    = "/laser";
final String ADDR_LASERPOS = "/laserpos";
final String ADDR_HEADS    = "/heads";
final String ADDR_ROOM     = "/room";

final boolean FORWARD_TOUCHES = true;

final float VOXEL          = 1.2;
final float CLUSTER_EPS    = 4.0;
final int   CLUSTER_MINPTS = 5;

// ====== LAYOUT ======
final int PANEL_W  = 240;
final int FOOTER_H = 36;
final int HEADER_H = 48;

final color C_BG       = color(18, 18, 20);
final color C_PANEL    = color(26, 26, 30);
final color C_BORDER   = color(55, 55, 62);
final color C_ACCENT   = color(29, 158, 117);
final color C_ACCENT2  = color(239, 159, 39);
final color C_RED      = color(220, 60, 60);
final color C_TEXT     = color(220, 220, 215);
final color C_MUTED    = color(110, 110, 105);
final color C_ZONE_DEF = color(40, 40, 48);

// ====== MODE ======
boolean testMode = false;  // false=LIVE, true=TEST

// ====== CIRCLE ZONES ======
final int   LASER_N   = 9;
final float DEFAULT_R = 120;
final float MIN_R     = 20;
final float MAX_R     = 400;

class CircleZone {
  boolean defined = false;
  float cx = 0, cy = 0;
  float r  = DEFAULT_R;
  void clear() { defined = false; }
  void setCenter(float x, float y) { cx=x; cy=y; defined=true; }
  boolean contains(float x, float y) {
    if (!defined) return false;
    float dx=x-cx, dy=y-cy;
    return dx*dx+dy*dy <= r*r;
  }
}

CircleZone[] lasers = new CircleZone[LASER_N];
int activeLaser = 0;
boolean detectEnabled = true;
final String LASER_FILE = "zones.json";

// ====== TEST mode motor PWM ======
int[] testPwm = new int[LASER_N];  // 0-255

// ====== Slider drag ======
int  dragZoneSlider  = -1;
int  dragMotorSlider = -1;
boolean dragging = false;

// ====== Shared state ======
final Object lock = new Object();
ArrayList<PVector> points     = new ArrayList<PVector>();
ArrayList<PVector> pointsBack = new ArrayList<PVector>();
float lastFrame = 0;
volatile int lastSeenMillis = 0;
int[] laserCount   = new int[LASER_N];
int[] laserPresent = new int[LASER_N];

float gScale=1, gOx=0, gOy=0;

// Zone panel geometry
int[] btnX = new int[LASER_N], btnY = new int[LASER_N];
int   btnW, btnH;
int[] zSliderX = new int[LASER_N], zSliderY = new int[LASER_N];
int   zSliderW;
final int SLIDER_H = 4;

// Test panel geometry (right side)
final int TEST_PANEL_W = 260;
int[] mSliderX = new int[LASER_N], mSliderY = new int[LASER_N];
int   mSliderW = 180;
int   mCardX, mCardW;

// Footer toolbar
int[] tbX = new int[4];

// Mode toggle button
int modeToggleX, modeToggleY, modeToggleW = 110, modeToggleH = 26;

// ====== Setup ======
void setup() {
  size(1400, 880, P2D);
  for (int i=0; i<LASER_N; i++) { lasers[i]=new CircleZone(); testPwm[i]=0; }
  oscP5 = new OscP5(this, OSC_IN_PORT);
  if (SEND_TO_MAX) maxAddr = new NetAddress(MAX_HOST, MAX_PORT);
  textFont(createFont("Monospaced", 13));
  lastSeenMillis = millis();
  buildLayout();
}

void buildLayout() {
  // Zone panel (left)
  int margin = 12;
  btnW = PANEL_W - margin*2;
  btnH = 70;
  zSliderW = btnW - 24;
  for (int i=0; i<LASER_N; i++) {
    btnX[i]    = margin;
    btnY[i]    = HEADER_H + 40 + i*(btnH+6);
    zSliderX[i] = btnX[i] + 12;
    zSliderY[i] = btnY[i] + btnH - 18;
  }

  // Test panel (right)
  mCardX = width - TEST_PANEL_W;
  mCardW = TEST_PANEL_W;
  for (int i=0; i<LASER_N; i++) {
    mSliderX[i] = mCardX + 56;
    mSliderY[i] = HEADER_H + 48 + i*62 + 28;
  }

  // Footer toolbar
  int tw = 88;
  for (int i=0; i<4; i++) tbX[i] = PANEL_W + 16 + i*(tw+8);

  // Mode toggle (top-right of header)
  modeToggleX = width - modeToggleW - 16;
  modeToggleY = HEADER_H/2 - modeToggleH/2;

  // Canvas
  float m = 28;
  float canvasRight = testMode ? width - TEST_PANEL_W : width;
  float cw = canvasRight - PANEL_W - m*2;
  float ch = height - HEADER_H - FOOTER_H - m*2;
  gScale = min(cw/OUTPUT_W, ch/OUTPUT_H);
  gOx = PANEL_W + m + (cw - OUTPUT_W*gScale)/2.0;
  gOy = HEADER_H + m + (ch - OUTPUT_H*gScale)/2.0;
}

// ====== Draw ======
void draw() {
  background(C_BG);

  if (millis()-lastSeenMillis>TIMEOUT_MS) {
    synchronized(lock) {
      points.clear(); lastFrame=0;
      for (int i=0;i<LASER_N;i++){laserCount[i]=0;laserPresent[i]=0;}
    }
  }

  ArrayList<PVector> snapPts;
  float snapFrame;
  int[] snapCount=new int[LASER_N], snapPres=new int[LASER_N];
  synchronized(lock) {
    snapPts=new ArrayList<PVector>(points);
    snapFrame=lastFrame;
    for (int i=0;i<LASER_N;i++){snapCount[i]=laserCount[i];snapPres[i]=laserPresent[i];}
  }

  // TEST mode: send motor values every frame
  if (testMode) {
    sendMotorOSC(testPwm);
  }

  drawZonePanel(snapPres, snapCount);
  drawHeader();
  drawCanvas(snapPts, snapPres, snapCount);
  if (testMode) drawTestPanel();
  drawFooter(snapPts, snapFrame);
}

// ====== Header ======
void drawHeader() {
  noStroke(); fill(C_PANEL); rect(0,0,width,HEADER_H);
  fill(C_BORDER); rect(0,HEADER_H-1,width,1);

  fill(C_TEXT); textSize(17); textAlign(LEFT,CENTER);
  text("wind load", PANEL_W+16, HEADER_H/2);
  fill(C_MUTED); textSize(12);
  text("circle zone detector  ·  OSC → M5", PANEL_W+148, HEADER_H/2);

  // DETECT badge
  textAlign(RIGHT,CENTER); noStroke();
  int badgeX = modeToggleX - 110;
  if (!testMode) {
    if (detectEnabled) {
      fill(C_ACCENT); rrect(badgeX, HEADER_H/2-11, 96, 22, 4);
      fill(255); textSize(11); text("● DETECT ON", badgeX+94, HEADER_H/2);
    } else {
      fill(50); rrect(badgeX, HEADER_H/2-11, 96, 22, 4);
      fill(C_MUTED); textSize(11); text("○ DETECT OFF", badgeX+94, HEADER_H/2);
    }
  }

  // Mode toggle button
  noStroke();
  if (testMode) {
    fill(C_RED); rrect(modeToggleX, modeToggleY, modeToggleW, modeToggleH, 5);
    fill(255); textSize(11); textAlign(CENTER,CENTER);
    text("● TEST", modeToggleX+modeToggleW/2, modeToggleY+modeToggleH/2);
  } else {
    fill(C_ACCENT); rrect(modeToggleX, modeToggleY, modeToggleW, modeToggleH, 5);
    fill(255); textSize(11); textAlign(CENTER,CENTER);
    text("◎ LIVE", modeToggleX+modeToggleW/2, modeToggleY+modeToggleH/2);
  }
  textAlign(LEFT,BASELINE);
}

// ====== Zone Panel (left) ======
void drawZonePanel(int[] snapPres, int[] snapCount) {
  noStroke(); fill(C_PANEL); rect(0,0,PANEL_W,height);
  fill(C_BORDER); rect(PANEL_W-1,0,1,height);

  fill(C_MUTED); textSize(10); textAlign(LEFT,TOP);
  text("ZONES", 12, HEADER_H+14);
  int def=0; for (int i=0;i<LASER_N;i++) if(lasers[i].defined) def++;
  textAlign(RIGHT,TOP); text(def+"/"+LASER_N+" defined", PANEL_W-12, HEADER_H+14);
  textAlign(LEFT,BASELINE);

  for (int i=0; i<LASER_N; i++) {
    boolean isAct  = (i==activeLaser && !testMode);
    boolean isPres = (snapPres[i]==1);
    boolean isDef  = lasers[i].defined;
    int bx=btnX[i], by=btnY[i];

    noStroke();
    if      (isPres&&isDef) fill(C_ACCENT2,45);
    else if (isAct)         fill(C_ACCENT,35);
    else                    fill(C_ZONE_DEF);
    rrect(bx,by,btnW,btnH,5);

    strokeWeight(1);
    if      (isAct)         stroke(C_ACCENT);
    else if (isPres&&isDef) stroke(C_ACCENT2);
    else                    stroke(C_BORDER);
    noFill(); rrect(bx,by,btnW,btnH,5); noStroke();

    textSize(13); textAlign(LEFT,TOP);
    fill(isAct?C_ACCENT:isPres?C_ACCENT2:C_TEXT);
    text("Z"+(i+1), bx+10, by+8);

    textSize(11); textAlign(RIGHT,TOP); fill(C_MUTED);
    text("r="+int(lasers[i].r), bx+btnW-8, by+8);

    textSize(10); textAlign(LEFT,TOP);
    if (isDef) {
      fill(isPres?C_ACCENT2:C_MUTED);
      text(isPres?"● "+snapCount[i]+" pts":"–", bx+10, by+26);
    } else {
      fill(C_BORDER); text("click to place", bx+10, by+26);
    }

    // radius slider
    int sx=zSliderX[i], sy=zSliderY[i];
    noStroke(); fill(C_BORDER); rect(sx,sy,zSliderW,SLIDER_H,2);
    float t=(lasers[i].r-MIN_R)/(MAX_R-MIN_R);
    fill(isAct?C_ACCENT:C_MUTED); rect(sx,sy,zSliderW*t,SLIDER_H,2);
    int tx=sx+int(zSliderW*t);
    fill(isAct?C_ACCENT:C_TEXT); circle(tx,sy+SLIDER_H/2,10);
  }
}

// ====== Test Panel (right) ======
void drawTestPanel() {
  // bg
  noStroke(); fill(C_PANEL);
  rect(mCardX, HEADER_H, TEST_PANEL_W, height-HEADER_H);
  fill(C_BORDER); rect(mCardX, HEADER_H, 1, height-HEADER_H);

  // title
  fill(C_RED); textSize(10); textAlign(LEFT,TOP);
  text("MOTOR TEST", mCardX+12, HEADER_H+14);

  // ALL OFF / ALL MAX buttons
  int bw=88, bh=24, by0=HEADER_H+32;
  // ALL OFF
  noStroke(); fill(C_ZONE_DEF); rrect(mCardX+8, by0, bw, bh, 4);
  stroke(C_BORDER); noFill(); rrect(mCardX+8, by0, bw, bh, 4); noStroke();
  fill(C_TEXT); textSize(11); textAlign(CENTER,CENTER);
  text("ALL OFF", mCardX+8+bw/2, by0+bh/2);
  // ALL MAX
  noStroke(); fill(C_ZONE_DEF); rrect(mCardX+8+bw+8, by0, bw, bh, 4);
  stroke(C_BORDER); noFill(); rrect(mCardX+8+bw+8, by0, bw, bh, 4); noStroke();
  fill(C_ACCENT2); textSize(11); textAlign(CENTER,CENTER);
  text("ALL MAX", mCardX+8+bw+8+bw/2, by0+bh/2);

  // Motor sliders
  for (int i=0; i<LASER_N; i++) {
    int sx=mSliderX[i], sy=mSliderY[i];
    int cardY = HEADER_H + 48 + i*62;

    // card bg
    noStroke(); fill(C_ZONE_DEF);
    rrect(mCardX+8, cardY, TEST_PANEL_W-16, 52, 4);
    stroke(testPwm[i]>0?C_RED:C_BORDER);
    noFill(); rrect(mCardX+8, cardY, TEST_PANEL_W-16, 52, 4); noStroke();

    // label
    textSize(12); textAlign(LEFT,CENTER);
    fill(testPwm[i]>0?C_RED:C_TEXT);
    text("M"+(i+1), mCardX+16, cardY+26);

    // pwm value
    textSize(12); textAlign(LEFT,CENTER);
    fill(testPwm[i]>0?C_ACCENT2:C_MUTED);
    text(nf(testPwm[i],3), mCardX+42, cardY+26);

    // slider track
    noStroke(); fill(C_BORDER); rect(sx, sy, mSliderW, SLIDER_H, 2);
    // fill
    float t=(float)testPwm[i]/255.0;
    if (t>0) {
      color sliderCol = lerpColor(C_ACCENT, C_RED, t);
      fill(sliderCol); rect(sx, sy, mSliderW*t, SLIDER_H, 2);
    }
    // thumb
    int tx=sx+int(mSliderW*t);
    fill(testPwm[i]>0?C_ACCENT2:C_TEXT); circle(tx, sy+SLIDER_H/2, 10);
  }
  textAlign(LEFT,BASELINE);
}

// ====== Canvas ======
void drawCanvas(ArrayList<PVector> snapPts, int[] snapPres, int[] snapCount) {
  float canvasRight = testMode ? mCardX : width;
  noStroke(); fill(22);
  rect(PANEL_W, HEADER_H, canvasRight-PANEL_W, height-HEADER_H-FOOTER_H);

  strokeWeight(1); stroke(C_BORDER); noFill();
  rect(gOx, gOy, OUTPUT_W*gScale, OUTPUT_H*gScale);

  stroke(30); strokeWeight(0.5);
  for (int gx=1;gx<4;gx++){float x=gOx+OUTPUT_W*gScale*gx/4.0;line(x,gOy,x,gOy+OUTPUT_H*gScale);}
  for (int gy=1;gy<4;gy++){float y=gOy+OUTPUT_H*gScale*gy/4.0;line(gOx,y,gOx+OUTPUT_W*gScale,y);}

  for (int i=0;i<LASER_N;i++) {
    if (!lasers[i].defined) continue;
    boolean isAct  = (i==activeLaser && !testMode);
    boolean isPres = (snapPres[i]==1);

    float sx=gOx+lasers[i].cx*gScale, sy=gOy+lasers[i].cy*gScale, sr=lasers[i].r*gScale;

    noStroke();
    if      (isPres) fill(C_ACCENT2,30);
    else if (isAct)  fill(C_ACCENT,20);
    else             fill(255,8);
    circle(sx,sy,sr*2);

    strokeWeight(isAct?2:1);
    stroke(isPres?C_ACCENT2:isAct?C_ACCENT:C_BORDER);
    noFill(); circle(sx,sy,sr*2);

    stroke(isPres?C_ACCENT2:C_MUTED,120); strokeWeight(1);
    line(sx-8,sy,sx+8,sy); line(sx,sy-8,sx,sy+8);

    noStroke();
    fill(isPres?C_ACCENT2:isAct?C_ACCENT:C_MUTED);
    textSize(isAct?14:11); textAlign(CENTER,CENTER);
    text("Z"+(i+1),sx,sy);
    if (isPres){textSize(10);text("n="+snapCount[i],sx,sy+14);}
    textAlign(LEFT,BASELINE);
  }

  // mouse preview
  if (!testMode && !lasers[activeLaser].defined &&
      mouseX>PANEL_W && mouseX<canvasRight &&
      mouseY>HEADER_H && mouseY<height-FOOTER_H) {
    float mx=constrain((mouseX-gOx)/gScale,0,OUTPUT_W);
    float my=constrain((mouseY-gOy)/gScale,0,OUTPUT_H);
    float sr=lasers[activeLaser].r*gScale;
    stroke(C_ACCENT2,80); strokeWeight(1); noFill(); circle(gOx+mx*gScale,gOy+my*gScale,sr*2);
    stroke(C_ACCENT2,120);
    line(gOx+mx*gScale-8,gOy+my*gScale,gOx+mx*gScale+8,gOy+my*gScale);
    line(gOx+mx*gScale,gOy+my*gScale-8,gOx+mx*gScale,gOy+my*gScale+8);
  }

  noStroke();
  for (PVector p:snapPts){fill(C_TEXT,200);circle(gOx+p.x*gScale,gOy+p.y*gScale,7);}
}

// ====== Footer ======
void drawFooter(ArrayList<PVector> snapPts, float snapFrame) {
  noStroke(); fill(C_PANEL); rect(0,height-FOOTER_H,width,FOOTER_H);
  fill(C_BORDER); rect(0,height-FOOTER_H,width,1);

  String[] labels={"C  clear","E  detect","S  save","L  load"};
  int tw=88;
  for (int i=0;i<4;i++){
    int bx=tbX[i],by=height-FOOTER_H+3;
    noStroke(); fill(C_ZONE_DEF); rrect(bx,by,tw,30,4);
    stroke(C_BORDER); noFill(); rrect(bx,by,tw,30,4);
    noStroke(); fill(C_TEXT); textSize(12); textAlign(CENTER,CENTER);
    text(labels[i],bx+tw/2,by+15);
  }

  // mode indicator
  textAlign(LEFT,CENTER); textSize(11);
  fill(testMode?C_RED:C_ACCENT);
  text(testMode?"MODE: TEST — LiDAR無効":"MODE: LIVE — LiDAR制御中",
    PANEL_W+16, height-FOOTER_H+FOOTER_H/2);

  textAlign(RIGHT,CENTER); fill(C_MUTED); textSize(11);
  text("pts="+snapPts.size()+"  frame="+nf(snapFrame,0,0)
    +"  OSC→"+MAX_HOST+":"+MAX_PORT,
    width-12, height-FOOTER_H+FOOTER_H/2);
  textAlign(LEFT,BASELINE);
}

// ====== Mouse ======
void mousePressed() {
  // mode toggle
  if (mouseX>=modeToggleX && mouseX<=modeToggleX+modeToggleW &&
      mouseY>=modeToggleY && mouseY<=modeToggleY+modeToggleH) {
    testMode = !testMode;
    // TEST切替時にモーターを全停止
    if (!testMode) { for(int i=0;i<LASER_N;i++) testPwm[i]=0; sendMotorOSC(testPwm); }
    buildLayout();
    return;
  }

  // TEST panel
  if (testMode && mouseX >= mCardX) {
    int bw=88, bh=24, by0=HEADER_H+32;
    // ALL OFF
    if (mouseX>=mCardX+8&&mouseX<=mCardX+8+bw&&mouseY>=by0&&mouseY<=by0+bh) {
      for(int i=0;i<LASER_N;i++) testPwm[i]=0; return;
    }
    // ALL MAX
    if (mouseX>=mCardX+8+bw+8&&mouseX<=mCardX+8+bw+8+bw&&mouseY>=by0&&mouseY<=by0+bh) {
      for(int i=0;i<LASER_N;i++) testPwm[i]=255; return;
    }
    // slider
    for (int i=0;i<LASER_N;i++) {
      int sx=mSliderX[i], sy=mSliderY[i];
      float t=(float)testPwm[i]/255.0;
      int tx=sx+int(mSliderW*t);
      if (dist(mouseX,mouseY,tx,sy+SLIDER_H/2)<10 ||
          (mouseX>=sx&&mouseX<=sx+mSliderW&&mouseY>=sy-6&&mouseY<=sy+SLIDER_H+6)) {
        dragging=true; dragMotorSlider=i; dragZoneSlider=-1;
        updateMotorSlider(i,mouseX); return;
      }
    }
    return;
  }

  // Zone panel
  if (mouseX < PANEL_W) {
    for (int i=0;i<LASER_N;i++) {
      float t=(lasers[i].r-MIN_R)/(MAX_R-MIN_R);
      int tx=zSliderX[i]+int(zSliderW*t);
      if (dist(mouseX,mouseY,tx,zSliderY[i]+SLIDER_H/2)<10 ||
          (mouseX>=zSliderX[i]&&mouseX<=zSliderX[i]+zSliderW&&
           mouseY>=zSliderY[i]-6&&mouseY<=zSliderY[i]+SLIDER_H+6)) {
        dragging=true; dragZoneSlider=i; dragMotorSlider=-1;
        activeLaser=i; updateZoneSlider(i,mouseX); return;
      }
      if (mouseX>=btnX[i]&&mouseX<=btnX[i]+btnW&&mouseY>=btnY[i]&&mouseY<=btnY[i]+btnH) {
        activeLaser=i; return;
      }
    }
    return;
  }

  // Footer toolbar
  int tw=88;
  if (mouseY>=height-FOOTER_H) {
    for (int i=0;i<4;i++) {
      if (mouseX>=tbX[i]&&mouseX<=tbX[i]+tw) {
        if (i==0) lasers[activeLaser].clear();
        if (i==1) detectEnabled=!detectEnabled;
        if (i==2) saveLasers();
        if (i==3) loadLasers();
        return;
      }
    }
    return;
  }

  // Canvas: place zone center (LIVE only)
  if (!testMode && mouseX>PANEL_W && mouseY>HEADER_H && mouseY<height-FOOTER_H) {
    float canvasRight = testMode ? mCardX : width;
    if (mouseX < canvasRight) {
      float rx=constrain((mouseX-gOx)/gScale,0,OUTPUT_W);
      float ry=constrain((mouseY-gOy)/gScale,0,OUTPUT_H);
      lasers[activeLaser].setCenter(rx,ry);
      for (int i=activeLaser+1;i<LASER_N;i++) { if(!lasers[i].defined){activeLaser=i;break;} }
    }
  }
}

void mouseDragged() {
  if (!dragging) return;
  if (dragMotorSlider>=0) updateMotorSlider(dragMotorSlider,mouseX);
  if (dragZoneSlider>=0)  updateZoneSlider(dragZoneSlider,mouseX);
}

void mouseReleased() { dragging=false; dragMotorSlider=-1; dragZoneSlider=-1; }

void updateMotorSlider(int id, int mx) {
  float t = constrain((float)(mx-mSliderX[id])/mSliderW, 0, 1);
  testPwm[id] = int(t*255);
}

void updateZoneSlider(int id, int mx) {
  float t = constrain((float)(mx-zSliderX[id])/zSliderW, 0, 1);
  lasers[id].r = MIN_R + t*(MAX_R-MIN_R);
}

void keyPressed() {
  if (keyCode==ESC){key=0;return;}
  if (key=='c'||key=='C') lasers[activeLaser].clear();
  if (key=='e'||key=='E') detectEnabled=!detectEnabled;
  if (key=='s'||key=='S') saveLasers();
  if (key=='l'||key=='L') loadLasers();
  if (key=='t'||key=='T') { testMode=!testMode; if(!testMode){for(int i=0;i<LASER_N;i++)testPwm[i]=0;sendMotorOSC(testPwm);} buildLayout(); }
}

// ====== OSC motor send ======
void sendMotorOSC(int[] pwmVals) {
  if (!SEND_TO_MAX) return;
  String motorCmd="";
  for (int li=0;li<LASER_N;li++) {
    motorCmd+=pwmVals[li];
    if (li<LASER_N-1) motorCmd+=",";
  }
  OscMessage om=new OscMessage("/motor"); om.add(motorCmd);
  oscP5.send(om,maxAddr);
}

// ====== Save / Load ======
void saveLasers() {
  JSONObject root=new JSONObject(); JSONArray arr=new JSONArray();
  for (int i=0;i<LASER_N;i++) {
    JSONObject z=new JSONObject();
    z.setBoolean("defined",lasers[i].defined);
    z.setFloat("cx",lasers[i].cx); z.setFloat("cy",lasers[i].cy); z.setFloat("r",lasers[i].r);
    arr.append(z);
  }
  root.setJSONArray("lasers",arr); saveJSONObject(root,LASER_FILE); println("saved");
}

void loadLasers() {
  JSONObject root=loadJSONObject(LASER_FILE); if(root==null){println("no file");return;}
  JSONArray arr=root.getJSONArray("lasers"); if(arr==null)return;
  for (int i=0;i<min(LASER_N,arr.size());i++) {
    JSONObject z=arr.getJSONObject(i);
    lasers[i].r=z.getFloat("r",DEFAULT_R);
    if (!z.getBoolean("defined")){lasers[i].clear();continue;}
    lasers[i].setCenter(z.getFloat("cx"),z.getFloat("cy"));
  }
  println("loaded");
}

// ====== Room normalize ======
float roomX(float x){return constrain(x/OUTPUT_W,0,1)*100.0;}
float roomY(float y){return constrain(1.0-(y/OUTPUT_H),0,1)*100.0;}

// ====== Voxel ======
ArrayList<PVector> voxelDownsample(ArrayList<PVector> inPts,float voxel){
  HashMap<Long,PVector> cell=new HashMap<Long,PVector>();
  for (PVector p:inPts){
    int gx=(int)floor(p.x/voxel),gy=(int)floor(p.y/voxel);
    long key=(((long)gx)<<32)^(gy&0xffffffffL);
    if (!cell.containsKey(key)) cell.put(key,p);
  }
  return new ArrayList<PVector>(cell.values());
}

// ====== DBSCAN ======
class Cluster{IntList idxs=new IntList();}
IntList regionQuery(ArrayList<PVector> pts,int i,float eps2){
  IntList res=new IntList();PVector a=pts.get(i);
  for(int j=0;j<pts.size();j++){PVector b=pts.get(j);float dx=a.x-b.x,dy=a.y-b.y;if(dx*dx+dy*dy<=eps2)res.append(j);}
  return res;
}
ArrayList<Cluster> dbscan(ArrayList<PVector> pts,float eps,int minPts){
  int n=pts.size();boolean[] vis=new boolean[n];int[] lbl=new int[n];
  float eps2=eps*eps;ArrayList<Cluster> clusters=new ArrayList<Cluster>();int cid=0;
  for(int i=0;i<n;i++){
    if(vis[i])continue;vis[i]=true;
    IntList neigh=regionQuery(pts,i,eps2);
    if(neigh.size()<minPts){lbl[i]=-1;continue;}
    cid++;Cluster c=new Cluster();clusters.add(c);lbl[i]=cid;c.idxs.append(i);
    for(int ni=0;ni<neigh.size();ni++){
      int p=neigh.get(ni);
      if(!vis[p]){vis[p]=true;IntList n2=regionQuery(pts,p,eps2);
        if(n2.size()>=minPts)for(int k=0;k<n2.size();k++){int q=n2.get(k);if(!neigh.hasValue(q))neigh.append(q);}
      }
      if(lbl[p]==0||lbl[p]==-1){lbl[p]=cid;c.idxs.append(p);}
    }
  }
  return clusters;
}
PVector medoidOfCluster(ArrayList<PVector> pts,IntList idxs){
  if(idxs.size()==0)return new PVector(-1,-1);
  int best=idxs.get(0);float bestS=Float.MAX_VALUE;
  for(int ai=0;ai<idxs.size();ai++){
    PVector a=pts.get(idxs.get(ai));float s=0;
    for(int bi=0;bi<idxs.size();bi++){PVector b=pts.get(idxs.get(bi));float dx=a.x-b.x,dy=a.y-b.y;s+=sqrt(dx*dx+dy*dy);}
    if(s<bestS){bestS=s;best=idxs.get(ai);}
  }
  return pts.get(best).copy();
}

// ====== OSC receive ======
void oscEvent(OscMessage m){
  if(!m.checkAddrPattern("/touches"))return;
  int n=m.arguments().length;if(n<3)return;
  lastSeenMillis=millis();
  float frame=getAsFloat(m,0);
  pointsBack.clear();
  int pairs=(n-1)/2,limit=(DROP_LAST_POINT&&pairs>=2)?pairs-1:pairs;
  int idx=1;
  for(int pi=0;pi<limit;pi++){float x=getAsFloat(m,idx++),y=getAsFloat(m,idx++);if(!Float.isNaN(x)&&!Float.isNaN(y))pointsBack.add(new PVector(x,y));}

  int[] newCount=new int[LASER_N],newPres=new int[LASER_N];
  ArrayList<Float>[] posLists=(ArrayList<Float>[])new ArrayList[LASER_N];
  for(int li=0;li<LASER_N;li++) posLists[li]=new ArrayList<Float>();

  if(detectEnabled&&!testMode){
    for(PVector p:pointsBack){
      for(int li=0;li<LASER_N;li++){
        if(!lasers[li].defined)continue;
        if(lasers[li].contains(p.x,p.y)){
          newCount[li]++;
          float dx=p.x-lasers[li].cx,dy=p.y-lasers[li].cy;
          float d=sqrt(dx*dx+dy*dy);
          posLists[li].add(constrain(d/lasers[li].r,0,1)*100.0);
        }
      }
    }
    for(int li=0;li<LASER_N;li++) newPres[li]=(newCount[li]>0)?1:0;
  }
  for(int li=0;li<LASER_N;li++) Collections.sort(posLists[li]);

  synchronized(lock){
    points.clear();points.addAll(pointsBack);lastFrame=frame;
    for(int li=0;li<LASER_N;li++){laserCount[li]=newCount[li];laserPresent[li]=newPres[li];}
  }

  if(!SEND_TO_MAX)return;

  if(FORWARD_TOUCHES){
    OscMessage ot=new OscMessage(ADDR_TOUCHES);ot.add(frame);
    for(PVector p:pointsBack){ot.add(p.x);ot.add(p.y);}
    oscP5.send(ot,maxAddr);
  }

  float rcx=-1,rcy=-1;
  if(pointsBack.size()>0){float sx=0,sy=0;for(PVector p:pointsBack){sx+=roomX(p.x);sy+=roomY(p.y);}rcx=sx/pointsBack.size();rcy=sy/pointsBack.size();}
  OscMessage or2=new OscMessage(ADDR_ROOM);or2.add(rcx);or2.add(rcy);oscP5.send(or2,maxAddr);

  ArrayList<PVector> roomPts=new ArrayList<PVector>();
  for(PVector p:pointsBack)roomPts.add(new PVector(roomX(p.x),roomY(p.y)));
  ArrayList<PVector> ds=voxelDownsample(roomPts,VOXEL);
  ArrayList<Cluster> cs=dbscan(ds,CLUSTER_EPS,CLUSTER_MINPTS);
  ArrayList<PVector> heads=new ArrayList<PVector>();
  for(Cluster c:cs){PVector rep=medoidOfCluster(ds,c.idxs);if(rep.x>=0)heads.add(rep);}
  Collections.sort(heads,new Comparator<PVector>(){public int compare(PVector a,PVector b){return a.x<b.x?-1:a.x>b.x?1:0;}});
  OscMessage oh=new OscMessage(ADDR_HEADS);oh.add(heads.size());for(PVector h:heads){oh.add(h.x);oh.add(h.y);}oscP5.send(oh,maxAddr);

  for(int li=0;li<LASER_N;li++){
    OscMessage ol=new OscMessage(ADDR_LASER);ol.add(li+1);ol.add(newPres[li]);ol.add(newCount[li]);ol.add(frame);oscP5.send(ol,maxAddr);
  }
  for(int li=0;li<LASER_N;li++){
    OscMessage op=new OscMessage(ADDR_LASERPOS);op.add(li+1);op.add(posLists[li].size());op.add(frame);for(float v:posLists[li])op.add(v);oscP5.send(op,maxAddr);
  }

  // LIVE mode: distance → PWM
  if(!testMode){
    int[] livePwm=new int[LASER_N];
    for(int li=0;li<LASER_N;li++){
      if(newPres[li]==1&&posLists[li].size()>0){
        float minDist=posLists[li].get(0);
        livePwm[li]=constrain(int(map(minDist,0,100,255,0)),0,255);
      }
    }
    sendMotorOSC(livePwm);
  }
}

float getAsFloat(OscMessage m,int idx){
  String tt=m.typetag();int off=(tt!=null&&tt.length()>0&&tt.charAt(0)==',')?1:0;
  char t='f';if(tt!=null&&idx+off<tt.length())t=tt.charAt(idx+off);
  try{if(t=='i')return(float)m.get(idx).intValue();if(t=='f')return m.get(idx).floatValue();if(t=='s')return float(m.get(idx).stringValue());return m.get(idx).floatValue();}catch(Exception e){return 0;}
}

void rrect(float x,float y,float w,float h,float r){
  beginShape();
  vertex(x+r,y);vertex(x+w-r,y);quadraticVertex(x+w,y,x+w,y+r);
  vertex(x+w,y+h-r);quadraticVertex(x+w,y+h,x+w-r,y+h);
  vertex(x+r,y+h);quadraticVertex(x,y+h,x,y+h-r);
  vertex(x,y+r);quadraticVertex(x,y,x+r,y);
  endShape(CLOSE);
}
