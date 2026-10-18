// GTA San Andreas style third-person camera for GoldSrc
// Lives in hlsdk-portable/cl_dll/tp_camera.cpp (picked up by the cl_dll wscript glob).
//
// Design: the server ALWAYS receives the aim angles (converged onto the crosshair).
// Body orientation is a client-side visual effect only.
#include "hud.h"
#include "cl_util.h"
#include "cvardef.h"
#include "const.h"
#include "usercmd.h"
#include "in_defs.h"
#include "ref_params.h"
#include "event_api.h"
#include "pm_defs.h"
#include "pmtrace.h"
#include <math.h>

#define TP_RAD2DEG ( 180.0f / 3.14159265f )

// Version of the default key bindings. 1 = Z and X, 3 = Alt (tpaim, toggle).
// Version 2 bound Alt to +tpaim (hold mode), which no longer exists.
#define TP_BINDS_VERSION 3

extern int g_iAlive;

cvar_t *cl_tp_enable;
cvar_t *cl_tp_dist;
cvar_t *cl_tp_shoulder;        // the SIGN of this cvar sets the camera side in every stance
cvar_t *cl_tp_height;          // vertical camera offset (positive = up)
cvar_t *cl_tp_turnspeed;
cvar_t *cl_tp_aimfix;
cvar_t *cl_tp_easetime;        // ease duration for shoulder, height and distance (s). 0 = instant
cvar_t *cl_tp_binds;           // version of the default bindings already applied; archived
cvar_t *cl_tp_autoadjust;      // 1 = height, distance and shoulder change while crouching
cvar_t *cl_tp_crouch_shoulder; // camera shoulder while crouch is held (magnitude)
cvar_t *cl_tp_crouch_height;   // camera height while crouch is held
cvar_t *cl_tp_crouch_dist;     // camera distance while crouch is held
cvar_t *cl_tp_aim_shoulder;    // camera shoulder while tpaim is on (magnitude)
cvar_t *cl_tp_aim_height;      // camera height while tpaim is on
cvar_t *cl_tp_aim_dist;        // camera distance while tpaim is on
cvar_t *cl_tp_aim_crouch_height; // camera height while tpaim is on and crouch is held (cl_tp_autoadjust 1)
cvar_t *cl_tp_autofp;          // 1 = automatic first person when the camera has no room
cvar_t *cl_tp_fp_in;           // free space below which the camera switches to first person
cvar_t *cl_tp_fp_out;          // free space from which the camera returns to third person

static float s_bodyYaw    = 0.0f;   // visual body orientation
static bool  s_init       = false;
static bool  s_aiming     = false;  // attack button held
static bool  s_ducking    = false;  // crouch button held
static bool  s_tpaim      = false;  // tpaim enabled (toggle)
static bool  s_wasActive  = false;
static bool  s_autoFirst  = false;  // automatic first person because of lack of room

// Camera state from the last render frame
static vec3_t s_camOrigin;
static vec3_t s_camAngles;
static vec3_t s_eyePos;
static bool   s_haveCam    = false;
static int    s_waterLevel = 0;

// Angles sent to the server in the last usercmd
static vec3_t s_shotAngles;
static bool   s_haveShot = false;

// Easing of the camera offsets
struct tp_ease_t
{
	float cur, from, to, t;
	bool  init;
};
static tp_ease_t s_easeShoulder = { 0.0f, 0.0f, 0.0f, 1.0f, false };
static tp_ease_t s_easeHeight   = { 0.0f, 0.0f, 0.0f, 1.0f, false };
static tp_ease_t s_easeDist     = { 0.0f, 0.0f, 0.0f, 1.0f, false };

// The mod is active: enabled and not in automatic first person
static bool TP_Active( void )
{
	return cl_tp_enable != NULL && cl_tp_enable->value != 0.0f && !s_autoFirst;
}

// Queried by CL_IsThirdPerson (in_camera.cpp)
int TP_IsThirdPerson( void )
{
	return TP_Active() ? 1 : 0;
}

// Flips the sign of cl_tp_shoulder (switches the camera shoulder)
static void TP_SwapShoulder( void )
{
	if ( cl_tp_shoulder == NULL )
		return;

	gEngfuncs.Cvar_SetValue( (char *)"cl_tp_shoulder", -cl_tp_shoulder->value );
}

// Toggles between first and third person
static void TP_Toggle( void )
{
	if ( cl_tp_enable == NULL )
		return;

	float v = ( cl_tp_enable->value != 0.0f ) ? 0.0f : 1.0f;
	gEngfuncs.Cvar_SetValue( (char *)"cl_tp_enable", v );
}

// tpaim: toggles aim mode (body locked to the crosshair, aim camera)
static void TP_AimToggle( void ) { s_tpaim = !s_tpaim; }

// Applies the default bindings once per version: Z and X (v1), Alt (v3).
// Afterwards the player can rebind freely: the keys and this cvar are saved in
// config.cfg. To repeat the process: cl_tp_binds 0
static void TP_DefaultBinds( void )
{
	if ( cl_tp_binds == NULL || cl_tp_binds->value >= (float)TP_BINDS_VERSION )
		return;

	if ( cl_tp_binds->value < 1.0f )
	{
		gEngfuncs.pfnClientCmd( (char *)"bind z cl_tp_toggle" );
		gEngfuncs.pfnClientCmd( (char *)"bind x cl_tp_swapshoulder" );
	}

	// Version 3: Alt toggles aim mode (it was +tpaim in version 2)
	gEngfuncs.pfnClientCmd( (char *)"bind alt tpaim" );

	gEngfuncs.Cvar_SetValue( (char *)"cl_tp_binds", (float)TP_BINDS_VERSION );
}

// Smoothstep easing. Any change of the target value (including the sign flip done by
// cl_tp_swapshoulder) starts a transition from the current position, so it can be
// reversed halfway without jumps.
static float TP_Ease( tp_ease_t *e, float target, float frametime, float duration )
{
	if ( !e->init || duration <= 0.0f )
	{
		e->cur = e->from = e->to = target;
		e->t = 1.0f;
		e->init = true;
		return e->cur;
	}

	if ( fabsf( target - e->to ) > 0.001f )
	{
		e->from = e->cur;
		e->to   = target;
		e->t    = 0.0f;
	}

	if ( e->t < 1.0f )
	{
		e->t += frametime / duration;
		if ( e->t > 1.0f )
			e->t = 1.0f;

		float k = e->t * e->t * ( 3.0f - 2.0f * e->t );
		e->cur = e->from + ( e->to - e->from ) * k;
	}

	return e->cur;
}

void TP_Init( void )
{
	cl_tp_enable          = gEngfuncs.pfnRegisterVariable( "cl_tp_enable",          "1",    FCVAR_ARCHIVE );
	cl_tp_dist            = gEngfuncs.pfnRegisterVariable( "cl_tp_dist",            "100",  FCVAR_ARCHIVE );
	cl_tp_shoulder        = gEngfuncs.pfnRegisterVariable( "cl_tp_shoulder",        "20",   FCVAR_ARCHIVE );
	cl_tp_height          = gEngfuncs.pfnRegisterVariable( "cl_tp_height",          "0",    FCVAR_ARCHIVE );
	cl_tp_turnspeed       = gEngfuncs.pfnRegisterVariable( "cl_tp_turnspeed",       "1000", FCVAR_ARCHIVE );
	cl_tp_aimfix          = gEngfuncs.pfnRegisterVariable( "cl_tp_aimfix",          "1",    FCVAR_ARCHIVE );
	cl_tp_easetime        = gEngfuncs.pfnRegisterVariable( "cl_tp_easetime",        "0.25", FCVAR_ARCHIVE );
	cl_tp_binds           = gEngfuncs.pfnRegisterVariable( "cl_tp_binds",           "0",    FCVAR_ARCHIVE );
	cl_tp_autoadjust      = gEngfuncs.pfnRegisterVariable( "cl_tp_autoadjust",      "1",    FCVAR_ARCHIVE );
	cl_tp_crouch_shoulder = gEngfuncs.pfnRegisterVariable( "cl_tp_crouch_shoulder", "20",   FCVAR_ARCHIVE );
	cl_tp_crouch_height   = gEngfuncs.pfnRegisterVariable( "cl_tp_crouch_height",   "20",   FCVAR_ARCHIVE );
	cl_tp_crouch_dist     = gEngfuncs.pfnRegisterVariable( "cl_tp_crouch_dist",     "75",   FCVAR_ARCHIVE );
	cl_tp_aim_shoulder    = gEngfuncs.pfnRegisterVariable( "cl_tp_aim_shoulder",    "15",   FCVAR_ARCHIVE );
	cl_tp_aim_height      = gEngfuncs.pfnRegisterVariable( "cl_tp_aim_height",      "0",    FCVAR_ARCHIVE );
	cl_tp_aim_dist        = gEngfuncs.pfnRegisterVariable( "cl_tp_aim_dist",        "48",   FCVAR_ARCHIVE );
	cl_tp_autofp          = gEngfuncs.pfnRegisterVariable( "cl_tp_autofp",          "1",    FCVAR_ARCHIVE );
	cl_tp_fp_in           = gEngfuncs.pfnRegisterVariable( "cl_tp_fp_in",           "24",   FCVAR_ARCHIVE );
	cl_tp_fp_out          = gEngfuncs.pfnRegisterVariable( "cl_tp_fp_out",          "40",   FCVAR_ARCHIVE );

	cl_tp_aim_crouch_height = gEngfuncs.pfnRegisterVariable( "cl_tp_aim_crouch_height", "20", FCVAR_ARCHIVE );

	gEngfuncs.pfnAddCommand( (char *)"cl_tp_swapshoulder", TP_SwapShoulder );
	gEngfuncs.pfnAddCommand( (char *)"cl_tp_toggle", TP_Toggle );
	gEngfuncs.pfnAddCommand( (char *)"tpaim", TP_AimToggle );
}

static float TP_AngleDiff( float a, float b )
{
	float d = a - b;
	while ( d >  180.0f ) d -= 360.0f;
	while ( d < -180.0f ) d += 360.0f;
	return d;
}

// Line trace against the world and entities that leaves the prediction state
// untouched (no Push/PopPMStates). If the ray hits the local player, that physent
// is ignored and the trace continues from the impact point, as V_GetChaseOrigin does.
static void TP_Trace( float *start, float *end, pmtrace_t *out )
{
	vec3_t from;
	int ignore   = -1;
	int localIdx = -1;

	cl_entity_t *local = gEngfuncs.GetLocalPlayer();
	if ( local )
		localIdx = local->index;

	VectorCopy( start, from );

	for ( int i = 0; i < 4; i++ )
	{
		// flags 0 = physents only, hull 2 = point hull
		pmtrace_t *tr = gEngfuncs.PM_TraceLine( from, end, 0, 2, ignore );
		*out = *tr;

		if ( tr->ent <= 0 )
			break;

		physent_t *pe = gEngfuncs.pEventAPI->EV_GetPhysent( tr->ent );
		if ( pe == NULL || pe->info != localIdx )
			break;

		ignore = tr->ent;
		VectorCopy( tr->endpos, from );
	}

	// Fraction relative to the original segment, not to the last leg
	float tx = end[0] - start[0], ty = end[1] - start[1], tz = end[2] - start[2];
	float px = out->endpos[0] - start[0], py = out->endpos[1] - start[1], pz = out->endpos[2] - start[2];
	float total = sqrtf( tx * tx + ty * ty + tz * tz );
	float part  = sqrtf( px * px + py * py + pz * pz );
	if ( total > 0.001f )
		out->fraction = part / total;
}

// Target camera values for the current stance. Priority:
//   1. tpaim on: cl_tp_aim_* (crouched with cl_tp_autoadjust 1: height cl_tp_aim_crouch_height)
//   2. crouch held with cl_tp_autoadjust 1: cl_tp_crouch_*
//   3. standing: cl_tp_shoulder, cl_tp_height, cl_tp_dist
// The camera side is set by the sign of cl_tp_shoulder: in stances 1 and 2 only the
// magnitude of their shoulder value is used, so cl_tp_swapshoulder (X) works in all.
static void TP_TargetValues( float *shoulder, float *height, float *dist )
{
	float side = ( cl_tp_shoulder->value < 0.0f ) ? -1.0f : 1.0f;

	if ( s_tpaim )
	{
		*shoulder = side * fabsf( cl_tp_aim_shoulder->value );
		*height   = cl_tp_aim_height->value;
		*dist     = cl_tp_aim_dist->value;

		// Crouched with autoadjust: the aim camera rises to its own height
		if ( cl_tp_autoadjust && cl_tp_autoadjust->value != 0.0f && s_ducking )
			*height = cl_tp_aim_crouch_height->value;
	}
	else if ( cl_tp_autoadjust && cl_tp_autoadjust->value != 0.0f && s_ducking )
	{
		*shoulder = side * fabsf( cl_tp_crouch_shoulder->value );
		*height   = cl_tp_crouch_height->value;
		*dist     = cl_tp_crouch_dist->value;
	}
	else
	{
		*shoulder = cl_tp_shoulder->value;
		*height   = cl_tp_height->value;
		*dist     = cl_tp_dist->value;
	}
}

// Places the camera and returns the free space behind the pivot (unclamped: it can
// be negative when geometry is right behind). The pivot is the eye offset by shoulder
// and height, without going through ceilings or walls.
static float TP_PlaceCamera( float *eye, float *camAng, float shoulder, float height, float dist, float *origin )
{
	vec3_t fwd, right, up, start, end;
	pmtrace_t tr;

	AngleVectors( camAng, fwd, right, up );

	VectorCopy( eye, start );
	VectorMA( start, shoulder, right, start );
	start[2] += height;

	// The lateral and vertical offsets must not go through ceilings or walls
	TP_Trace( eye, start, &tr );
	if ( tr.fraction < 1.0f )
	{
		float ox   = start[0] - eye[0];
		float oy   = start[1] - eye[1];
		float oz   = start[2] - eye[2];
		float olen = sqrtf( ox * ox + oy * oy + oz * oz );

		if ( olen > 0.001f )
		{
			float keep = tr.fraction * olen - 4.0f;
			if ( keep < 0.0f )
				keep = 0.0f;

			float sc = keep / olen;
			start[0] = eye[0] + ox * sc;
			start[1] = eye[1] + oy * sc;
			start[2] = eye[2] + oz * sc;
		}
	}

	VectorMA( start, -dist, fwd, end );
	TP_Trace( start, end, &tr );

	float avail = tr.fraction * dist - 8.0f;
	float d     = avail;
	if ( d < 8.0f )
		d = 8.0f;

	VectorMA( start, -d, fwd, origin );
	return avail;
}

// Shot convergence: the ray through the screen center (camera) fixes the impact
// point and the aim leaves the eye towards that point.
static void TP_ConvergeAim( float *angles )
{
	vec3_t fwd, right, up, end, hit, dir;
	pmtrace_t tr;

	AngleVectors( s_camAngles, fwd, right, up );
	VectorMA( s_camOrigin, 8192.0f, fwd, end );
	TP_Trace( s_camOrigin, end, &tr );
	VectorMA( s_camOrigin, tr.fraction * 8192.0f, fwd, hit );

	dir[0] = hit[0] - s_eyePos[0];
	dir[1] = hit[1] - s_eyePos[1];
	dir[2] = hit[2] - s_eyePos[2];

	float flat = sqrtf( dir[0] * dir[0] + dir[1] * dir[1] );
	float len  = sqrtf( flat * flat + dir[2] * dir[2] );
	float dot  = dir[0] * fwd[0] + dir[1] * fwd[1] + dir[2] * fwd[2];

	// Impact too close or behind the shooter: keep the camera direction
	if ( len < 48.0f || dot <= 0.0f )
		return;

	angles[YAW]   =  atan2f( dir[1], dir[0] ) * TP_RAD2DEG;
	angles[PITCH] = -atan2f( dir[2], flat )   * TP_RAD2DEG;
}

// Call at the end of CL_CreateMove, after cmd->viewangles has been assigned
void TP_ApplyMove( float frametime, struct usercmd_s *cmd )
{
	// Apply any pending default bindings (runs in first person too)
	TP_DefaultBinds();

	// Stance from the crouch button (cl_tp_autoadjust)
	s_ducking = ( cmd->buttons & IN_DUCK ) != 0;

	if ( !TP_Active() || !g_iAlive )
	{
		s_haveShot  = false;
		s_haveCam   = false;
		s_wasActive = false;
		return;
	}

	vec3_t camAng, sent;
	gEngfuncs.GetViewAngles( camAng );   // mouse angles = camera orbit

	// When the mode is (re)activated, the body reorients towards the camera
	if ( !s_wasActive )
	{
		s_init = false;
		s_wasActive = true;
	}

	if ( !s_init )
	{
		s_bodyYaw = camAng[YAW];
		s_init = true;
	}

	s_aiming = ( cmd->buttons & IN_ATTACK ) != 0;
	bool swimming  = ( s_waterLevel >= 2 );
	bool facingAim = s_aiming || s_tpaim;   // the body stays locked to the crosshair

	// Angles that travel to the server: always the camera aim
	VectorCopy( camAng, sent );
	sent[ROLL] = 0.0f;

	// Converge onto the crosshair (RPG laser, weapons, +use...).
	// While swimming and not aiming, the exact camera angle is kept.
	if ( cl_tp_aimfix && cl_tp_aimfix->value != 0.0f && s_haveCam && ( facingAim || !swimming ) )
		TP_ConvergeAim( sent );

	VectorCopy( sent, cmd->viewangles );
	VectorCopy( sent, s_shotAngles );
	s_haveShot = true;

	float fwd  = cmd->forwardmove;
	float side = cmd->sidemove;
	float mag  = sqrtf( fwd * fwd + side * side );

	// Desired movement direction, relative to the camera
	float world = camAng[YAW] + atan2f( -side, fwd ) * TP_RAD2DEG;

	// Visual body orientation
	if ( facingAim || swimming )
	{
		s_bodyYaw = sent[YAW];
	}
	else if ( mag > 1.0f )
	{
		float diff = TP_AngleDiff( world, s_bodyYaw );
		float step = cl_tp_turnspeed->value * frametime;

		if ( fabsf( diff ) <= step )
			s_bodyYaw = world;
		else
			s_bodyYaw += ( diff > 0 ? step : -step );
	}

	// Out of water, movement follows the camera even when the sent yaw differs
	// because of the convergence: it is re-expressed relative to the sent yaw.
	if ( !swimming && mag > 1.0f )
	{
		float rel = ( world - sent[YAW] ) * ( 3.14159265f / 180.0f );
		cmd->forwardmove =  mag * cosf( rel );
		cmd->sidemove    = -mag * sinf( rel );
	}
}

// Space probe: switches to first person when the camera does not fit behind the
// character and returns to third person when there is room (with hysteresis).
// Call every frame from V_CalcNormalRefdef, before CL_IsThirdPerson is queried.
void TP_UpdateAuto( struct ref_params_s *pparams )
{
	if ( cl_tp_enable == NULL || cl_tp_enable->value == 0.0f
		|| cl_tp_autofp == NULL || cl_tp_autofp->value == 0.0f
		|| !g_iAlive || pparams->intermission
		|| pparams->viewentity != pparams->playernum + 1 )
	{
		s_autoFirst = false;
		return;
	}

	vec3_t camAng, unused;
	VectorCopy( pparams->cl_viewangles, camAng );
	camAng[ROLL] = 0.0f;

	float tShoulder, tHeight, tDist;
	TP_TargetValues( &tShoulder, &tHeight, &tDist );

	float avail = TP_PlaceCamera( pparams->vieworg, camAng, tShoulder, tHeight, tDist, unused );

	float in  = cl_tp_fp_in  ? cl_tp_fp_in->value  : 24.0f;
	float out = cl_tp_fp_out ? cl_tp_fp_out->value : 40.0f;
	if ( out < in + 4.0f )
		out = in + 4.0f;

	// With short distances (tpaim) the maximum measurable space is smaller: the
	// thresholds are capped so that returning to third person stays possible
	float cap = tDist - 9.0f;
	if ( out > cap )
		out = cap;
	if ( in > out - 4.0f )
		in = out - 4.0f;

	if ( !s_autoFirst && avail < in )
		s_autoFirst = true;
	else if ( s_autoFirst && avail >= out )
		s_autoFirst = false;
}

// Call from V_CalcNormalRefdef in place of the original camera block
void TP_CalcCamera( struct ref_params_s *pparams, float *outAngles )
{
	vec3_t camAng;

	VectorCopy( pparams->cl_viewangles, camAng );
	camAng[ROLL] = 0.0f;

	float tShoulder, tHeight, tDist;
	TP_TargetValues( &tShoulder, &tHeight, &tDist );

	float easeTime = cl_tp_easetime ? cl_tp_easetime->value : 0.0f;
	float shoulder = TP_Ease( &s_easeShoulder, tShoulder, pparams->frametime, easeTime );
	float height   = TP_Ease( &s_easeHeight,   tHeight,   pparams->frametime, easeTime );
	float dist     = TP_Ease( &s_easeDist,     tDist,     pparams->frametime, easeTime );

	s_waterLevel = pparams->waterlevel;

	// Eye position before the camera moves (origin of the shot)
	VectorCopy( pparams->vieworg, s_eyePos );

	TP_PlaceCamera( s_eyePos, camAng, shoulder, height, dist, pparams->vieworg );

	VectorCopy( pparams->vieworg, s_camOrigin );
	VectorCopy( camAng, s_camAngles );
	s_haveCam = true;

	// view.cpp later copies camAngles into pparams->viewangles
	VectorCopy( camAng, outAngles );
}

// Call from V_CalcNormalRefdef next to the local player's pitch adjustment.
// Only touches the local player entity: during cutscenes the view entity is a
// different one and its yaw defines the camera.
void TP_ApplyBodyYaw( struct cl_entity_s *ent )
{
	if ( ent == NULL || !TP_Active() || !g_iAlive || !s_init )
		return;

	if ( ent != gEngfuncs.GetLocalPlayer() )
		return;

	ent->angles[YAW]             = s_bodyYaw;
	ent->curstate.angles[YAW]    = s_bodyYaw;
	ent->prevstate.angles[YAW]   = s_bodyYaw;
	ent->latched.prevangles[YAW] = s_bodyYaw;
}

// Angles for client-side predicted events (gauss, egon, glock, mp5...).
// They use the same angles that travelled in the usercmd.
void TP_OverrideAngles( float *angles )
{
	if ( !TP_Active() || !s_haveShot )
		return;

	VectorCopy( s_shotAngles, angles );
}

// Call at the start of EV_HLDM_FireBullets for the local player.
void TP_OverrideShot( float *forward, float *right, float *up, float *dir )
{
	if ( !TP_Active() || !s_haveShot )
		return;

	AngleVectors( s_shotAngles, forward, right, up );
	dir[0] = forward[0];
	dir[1] = forward[1];
	dir[2] = forward[2];
}
