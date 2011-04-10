////////////////////////////////////////////////////////////////////////////////
//
//  Monte Carlo eXtreme (MCX)  - GPU accelerated Monte Carlo 3D photon migration
//      -- OpenCL edition
//  Author: Qianqian Fang <fangq at nmr.mgh.harvard.edu>
//
//  Reference (Fang2009):
//        Qianqian Fang and David A. Boas, "Monte Carlo Simulation of Photon 
//        Migration in 3D Turbid Media Accelerated by Graphics Processing 
//        Units," Optics Express, vol. 17, issue 22, pp. 20178-20190 (2009)
//
//  mcx_core.cl: OpenCL kernels
//
//  Unpublished work, see LICENSE.txt for details
//
////////////////////////////////////////////////////////////////////////////////

#ifdef SAVE_DETECTORS
  #pragma OPENCL EXTENSION cl_khr_global_int32_base_atomics : enable
#endif

#ifdef __DEVICE_EMULATION__
  #define GPUDEBUG(x)        printf x             // enable debugging in CPU mode
  #pragma OPENCL EXTENSION cl_amd_printf : enable
#else
  #define GPUDEBUG(x)
#endif

#define RAND_BUF_LEN       5        //register arrays
#define RAND_SEED_LEN      5        //32bit seed length (32*5=160bits)
#define R_PI               0.318309886183791f
#define INIT_LOGISTIC      100

#define RAND_MAX 4294967295

#define ONE_PI             3.1415926535897932f     //pi
#define TWO_PI             6.28318530717959f       //2*pi
#define EPS                1e-10f                  //round-off limit

#define C0                 299792458000.f          //speed of light in mm/s
#define R_C0               3.335640951981520e-12f  //1/C0 in s/mm

#define VERY_BIG           1e10f                   //a big number
#define JUST_ABOVE_ONE     1.0001f                 //test for boundary
#define SAME_VOXEL         -9999.f                 //scatter within a voxel
#define MAX_PROP           256                     //maximum property number

#define DET_MASK           0x80
#define MED_MASK           0x7F
#define NULL               0

typedef struct KernelParams {
  float4 ps,c0;
  float4 maxidx;
  uint4  dimlen,cp0,cp1;
  uint2  cachebox;
  float  minstep;
  float  twin0,twin1,tmax;
  float  oneoverc0;
  unsigned int isrowmajor,save2pt,doreflect,dorefint,savedet;
  float  Rtstep;
  float  minenergy;
  float  skipradius2;
  float  minaccumtime;
  unsigned int maxdetphoton;
  unsigned int maxmedia;
  unsigned int detnum;
  unsigned int idx1dorig;
  unsigned int mediaidorig;
}MCXParam __attribute__ ((aligned (16)));


#ifndef DOUBLE_PREC_LOGISTIC
  typedef float RandType;
  #define FUN(x)               (4.f*(x)*(1.f-(x)))
  #define NU 1e-8f
  #define NU2 (1.f-2.f*NU)
  #define MIN_INVERSE_LIMIT 1e-7f
  #define logistic_uniform(v)  (acos(1.f-2.f*(v))*R_PI)
  #define R_MAX_C_RAND       (1.f/RAND_MAX)
  #define LOG_MT_MAX         22.1807097779182f
#else
  typedef double RandType;
  #define FUN(x)               (4.0*(x)*(1.0-(x)))
  #define NU 1e-14
  #define NU2 (1.0-2.0*NU)
  #define MIN_INVERSE_LIMIT 1e-12
  #define logistic_uniform(v)  (acos(1.0-2.0*(v))*R_PI)
  #define R_MAX_C_RAND       (1./RAND_MAX)
  #define LOG_MT_MAX         22.1807097779182
#endif

#define RING_FUN(x,y,z)      (NU2*(x)+NU*((y)+(z)))


void logistic_step(RandType *t, RandType *tnew, int len_1){
    RandType tmp;
    t[0]=FUN(t[0]);
    t[1]=FUN(t[1]);
    t[2]=FUN(t[2]);
    t[3]=FUN(t[3]);
    t[4]=FUN(t[4]);
    tnew[3]=RING_FUN(t[0],t[4],t[1]);   /* shuffle the results by separation of 2*/
    tnew[4]=RING_FUN(t[1],t[0],t[2]);
    tnew[0]=RING_FUN(t[2],t[1],t[3]);
    tnew[1]=RING_FUN(t[3],t[2],t[4]);
    tnew[2]=RING_FUN(t[4],t[3],t[0]);
    tmp =t[0];
    t[0]=t[2];
    t[2]=t[4];
    t[4]=t[1];
    t[1]=t[3];
    t[3]=tmp;
}
// generate random number for the next zenith angle
void rand_need_more(RandType t[RAND_BUF_LEN],RandType tbuf[RAND_BUF_LEN]){
    logistic_step(t,tbuf,RAND_BUF_LEN-1);
    logistic_step(tbuf,t,RAND_BUF_LEN-1);
}

void logistic_init(RandType *t,RandType *tnew,__global uint seed[],uint idx){
     int i;
     for(i=0;i<RAND_BUF_LEN;i++)
           t[i]=(RandType)seed[idx*RAND_BUF_LEN+i]*R_MAX_C_RAND;

     for(i=0;i<INIT_LOGISTIC;i++)  /*initial randomization*/
           rand_need_more(t,tnew);
}
// transform into [0,1] random number
RandType rand_uniform01(RandType v){
    return logistic_uniform(v);
}
void gpu_rng_init(RandType t[RAND_BUF_LEN], RandType tnew[RAND_BUF_LEN],__global uint *n_seed,int idx){
    logistic_init(t,tnew,n_seed,idx);
}
// generate [0,1] random number for the next scattering length
float rand_next_scatlen(RandType t[RAND_BUF_LEN]){
    RandType ran=rand_uniform01(t[0]);
    return ((ran==0.f)?LOG_MT_MAX:(-log(ran)));
}
// generate [0,1] random number for the next arimuthal angle
float rand_next_aangle(RandType t[RAND_BUF_LEN]){
    return rand_uniform01(t[2]);
}
// generate random number for the next zenith angle
float rand_next_zangle(RandType t[RAND_BUF_LEN]){
    return rand_uniform01(t[4]);
}
// generate random number for the next zenith angle
float rand_next_reflect(RandType t[RAND_BUF_LEN]){
    return rand_uniform01(t[1]);
}

void clearpath(__local float *p, __constant MCXParam gcfg[]){
      uint i;
      for(i=0;i<gcfg->maxmedia;i++)
      	   p[i]=0.f;
}

#ifdef SAVE_DETECTORS
uint finddetector(float4 p0[],__constant float4 gdetpos[],__constant MCXParam gcfg[]){
      uint i;
      for(i=0;i<gcfg->detnum;i++){
      	if((gdetpos[i].x-p0[0].x)*(gdetpos[i].x-p0[0].x)+
	   (gdetpos[i].y-p0[0].y)*(gdetpos[i].y-p0[0].y)+
	   (gdetpos[i].z-p0[0].z)*(gdetpos[i].z-p0[0].z) < gdetpos[i].w){
	        return i+1;
	   }
      }
      return 0;
}

void savedetphoton(__global float n_det[],__global uint *detectedphoton,float weight,
                   __local float *ppath,float4 p0[],__constant float4 gdetpos[],__constant MCXParam gcfg[]){
      uint j,baseaddr=0;
      j=finddetector(p0,gdetpos,gcfg);
      if(j){
         //baseaddr=(++ (*detectedphoton));
	 baseaddr=atomic_add(detectedphoton,1);
	 if(baseaddr<gcfg->maxdetphoton){
	    baseaddr*=gcfg->maxmedia+2;
	    n_det[baseaddr++]=j;
	    n_det[baseaddr++]=weight;
	    for(j=0;j<gcfg->maxmedia;j++){
		n_det[baseaddr+j]=ppath[j]; // save partial pathlength to the memory
	    }
	 }
      }
}
#endif


void launchnewphoton(float4 p[],float4 v[],float4 f[],float4 prop[],uint *idx1d,
           uint *mediaid,uchar isdet, __local float ppath[],float energyloss[],float energyabsorbed[],
	   __global float n_det[],__global uint *dpnum, __constant float4 gproperty[],
	   __constant float4 gdetpos[],__constant MCXParam gcfg[]){

      *energyloss+=p[0].w;  // sum all the remaining energy
      *energyabsorbed+=1.f-p[0].w;
#ifdef SAVE_DETECTORS
      // let's handle detectors here
      if(gcfg->savedet){
         if(*mediaid==0 && isdet){
	      savedetphoton(n_det,dpnum,v[0].w,ppath,p,gdetpos,gcfg);
	 }
	 clearpath(ppath,gcfg);
      }
#endif
      p[0]=gcfg->ps;
      v[0]=gcfg->c0;
      f[0].x=0.f;f[0].y=0.f;f[0].z=gcfg->minaccumtime;f[0].w=f[0].w+1;
      *idx1d=gcfg->idx1dorig;
      *mediaid=gcfg->mediaidorig;
      prop[0]=gproperty[*mediaid]; //always use mediaid to read gproperty[]
}

/*
   this is the core Monte Carlo simulation kernel, please see Fig. 1 in Fang2009
*/
__kernel void mcx_main_loop( const int nphoton, const int ophoton,__global const uchar media[],
     __global float field[], __global float genergy[], __global uint n_seed[],__global float4 n_pos[],
     __global float4 n_dir[],__global float4 n_len[],__global float n_det[],__constant float4 gproperty[],
     __constant float4 gdetpos[], __global uint stopsign[1],__global uint detectedphoton[1],
     __local float *sharedmem, __constant MCXParam gcfg[]){

     int idx= get_global_id(0);

     float4 p=gcfg->ps;  //{x,y,z}: x,y,z coordinates,{w}:packet weight
     float4 v=gcfg->c0;  //{x,y,z}: ix,iy,iz unitary direction vector, {w}:total scat event
                              //v.w can be dropped to save register
     float4 f=n_len[idx];  //f.w can be dropped to save register
     float4 p0;            //reflection var, to save pre-reflection p state
     float  energyloss=genergy[idx<<1];
     float  energyabsorbed=genergy[(idx<<1)+1];

     uint idx1d, idx1dold;   //idx1dold is related to reflection
     int np= (idx<ophoton) ? nphoton+1 : nphoton;

#ifdef TEST_RACING
     int cc=0;
#endif
     uint  mediaid,mediaidold;
     int   medid=-1;
     float  atten;         //can be taken out to minimize registers
     float  n1,Rtotal;   //reflection var

     //for MT RNG, these will be zero-length arrays and be optimized out
     RandType t[RAND_BUF_LEN],tnew[RAND_BUF_LEN];
     float4 prop;    //can become float2 if no reflection

     float len,cphi,sphi,theta,stheta,ctheta,tmp0,tmp1;
     float accumweight=0.f;
     __local float *ppath=sharedmem+get_local_id(0)*gcfg->maxmedia;

     gpu_rng_init(t,tnew,n_seed,idx);

     // assuming the initial position is within the domain (mcx_config is supposed to ensure)
     idx1d=gcfg->idx1dorig;
     mediaid=gcfg->mediaidorig;

     if(mediaid==0) {
          return; // the initial position is not within the medium
     }
     prop=gproperty[mediaid];

     while(f.w<np) {

          GPUDEBUG(("*i= (%d) L=%f w=%e a=%f\n",(int)f.w,f.x,p.w,f.y));
	  if(f.x<=0.f) {  // if this photon has finished the current jump
               rand_need_more(t,tnew);
   	       f.x=rand_next_scatlen(t);

               GPUDEBUG(("next scat len=%20.16e \n",f.x));
	       if(p.w<1.f){ //weight
                       //random arimuthal angle
                       tmp0=TWO_PI*rand_next_aangle(t); //next arimuth angle
                       sphi=sincos(tmp0,&cphi);
                       GPUDEBUG(("next angle phi %20.16e\n",tmp0));

                       //Henyey-Greenstein Phase Function, "Handbook of Optical Biomedical Diagnostics",2002,Chap3,p234
                       //see Boas2002

                       if(prop.w>EPS){  //if prop.w is too small, the distribution of theta is bad
		           tmp0=(1.f-prop.w*prop.w)/(1.f-prop.w+2.f*prop.w*rand_next_zangle(t));
		           tmp0*=tmp0;
		           tmp0=(1.f+prop.w*prop.w-tmp0)/(2.f*prop.w);

                           // when ran=1, CUDA will give me 1.000002 for tmp0 which produces nan later
                           // detected by Ocelot,thanks to Greg Diamos,see http://bit.ly/cR2NMP
                           tmp0=max(-1.f, min(1.f, tmp0));

		           theta=acos(tmp0);
		           stheta=sin(theta);
		           ctheta=tmp0;
                       }else{  //Wang1995 has acos(2*ran-1), rather than 2*pi*ran, need to check
			   theta=ONE_PI*rand_next_zangle(t);
                           stheta=sincos(theta,&ctheta);
                       }
                       GPUDEBUG(("next scat angle theta %20.16e\n",theta));

		       if( v.z>-1.f+EPS && v.z<1.f-EPS ) {
		           tmp0=1.f-v.z*v.z;   //reuse tmp to minimize registers
		           tmp1=rsqrt(tmp0);
		           tmp1=stheta*tmp1;
		           v=(float4)(
				tmp1*(v.x*v.z*cphi - v.y*sphi) + v.x*ctheta,
				tmp1*(v.y*v.z*cphi + v.x*sphi) + v.y*ctheta,
				-tmp1*tmp0*cphi                         + v.z*ctheta,
				v.w
			   );
                           GPUDEBUG(("new dir: %10.5e %10.5e %10.5e\n",v.x,v.y,v.z));
		       }else{
			   v=(float4)(stheta*cphi,stheta*sphi,(v.z>0.f)?ctheta:-ctheta,v.w);
                           GPUDEBUG(("new dir-z: %10.5e %10.5e %10.5e\n",v.x,v.y,v.z));
 		       }
                       v.w+=1.f;
	       }
	  }

          n1=prop.z;
	  prop=gproperty[mediaid];
	  len=gcfg->minstep*prop.y; //Wang1995: gcfg->minstep*(prop.x+prop.y)

          p0=p;
	  if(len>f.x){  //scattering ends in this voxel: mus*gcfg->minstep > s 
               tmp0=f.x/prop.y;
	       p.xyz+=v.xyz*tmp0;
               p.w=p.w*exp(-prop.x*tmp0);
	       f.x=SAME_VOXEL;
	       f.y+=tmp0*prop.z*R_C0;  // accumulative time
               GPUDEBUG((">>ends in voxel %f<%f %f [%d]\n",f.x,len,prop.y,idx1d));
	  }else{                      //otherwise, move gcfg->minstep
               if(mediaid!=medid){
                  atten=exp(-prop.x*gcfg->minstep);
               }
               p.xyz+=v.xyz;
               p.w*=atten;
               medid=mediaid;
	       f.x-=len;     //remaining probability: sum(s_i*mus_i)
	       f.y+=gcfg->minaccumtime*prop.z; //total time
               GPUDEBUG((">>keep going %f<%f %f [%d] %e %e\n",f.x,len,prop.y,idx1d,f.y,f.z));
	  }

          mediaidold=media[idx1d];
          idx1dold=idx1d;
          idx1d=((int)floor(p.z)*gcfg->dimlen.y+(int)floor(p.y)*gcfg->dimlen.x+(int)floor(p.x));
          GPUDEBUG(("old and new voxel: %d<->%d\n",idx1dold,idx1d));
          if(p.x<0||p.y<0||p.z<0||p.x>=gcfg->maxidx.x||p.y>=gcfg->maxidx.y||p.z>=gcfg->maxidx.z){
	      mediaid=0;
	  }else{
              mediaid=media[idx1d];
          }
	  
          //if hit the boundary, exceed the max time window or exit the domain, rebound or launch a new one
	  if(mediaid==0||f.y>gcfg->tmax||f.y>gcfg->twin1){
              float flipdir=0.f;
              float4 htime;            //reflection var

              if(gcfg->doreflect) {
                //time-of-flight to hit the wall in each direction
                htime.x=(v.x>EPS||v.x<-EPS)?(floor(p0.x)+(v.x>0.f)-p0.x)/v.x:VERY_BIG;
                htime.y=(v.y>EPS||v.y<-EPS)?(floor(p0.y)+(v.y>0.f)-p0.y)/v.y:VERY_BIG;
                htime.z=(v.z>EPS||v.z<-EPS)?(floor(p0.z)+(v.z>0.f)-p0.z)/v.z:VERY_BIG;
                //get the direction with the smallest time-of-flight
                tmp0=fmin(fmin(htime.x,htime.y),htime.z);
                flipdir=(tmp0==htime.x?1.f:(tmp0==htime.y?2.f:(tmp0==htime.z&&idx1d!=idx1dold)?3.f:0.f));

                //move to the 1st intersection pt
                tmp0*=JUST_ABOVE_ONE;
                htime.x=floor(p0.x+tmp0*v.x);
       	        htime.y=floor(p0.y+tmp0*v.y);
       	        htime.z=floor(p0.z+tmp0*v.z);

                if(htime.x>=0&&htime.y>=0&&htime.z>=0&&htime.x<gcfg->maxidx.x&&htime.y<gcfg->maxidx.y&&htime.z<gcfg->maxidx.z){
                    if(media[(int)(htime.z*gcfg->dimlen.y+htime.y*gcfg->dimlen.x+htime.x)]==mediaidold){ //if the first vox is not air

                     GPUDEBUG((" first try failed: [%.1f %.1f,%.1f] %d (%.1f %.1f %.1f)\n",htime.x,htime.y,htime.z,
                           media[(int)(htime.z*gcfg->dimlen.y+htime.y*gcfg->dimlen.x+htime.x)], gcfg->maxidx.x, gcfg->maxidx.y,gcfg->maxidx.z));

                     htime.x=(v.x>EPS||v.x<-EPS)?(floor(p.x)+(v.x<0.f)-p.x)/(-v.x):VERY_BIG;
                     htime.y=(v.y>EPS||v.y<-EPS)?(floor(p.y)+(v.y<0.f)-p.y)/(-v.y):VERY_BIG;
                     htime.z=(v.z>EPS||v.z<-EPS)?(floor(p.z)+(v.z<0.f)-p.z)/(-v.z):VERY_BIG;
                     tmp0=fmin(fmin(htime.x,htime.y),htime.z);
                     tmp1=flipdir;   //save the previous ref. interface id
                     flipdir=(tmp0==htime.x?1.f:(tmp0==htime.y?2.f:(tmp0==htime.z&&idx1d!=idx1dold)?3.f:0.f));

                     if(gcfg->doreflect){
                       tmp0*=JUST_ABOVE_ONE;
                       htime.x=floor(p.x-tmp0*v.x); //move to the last intersection pt
                       htime.y=floor(p.y-tmp0*v.y);
                       htime.z=floor(p.z-tmp0*v.z);

                       if(tmp1!=flipdir&&htime.x>=0&&htime.y>=0&&htime.z>=0&&htime.x<gcfg->maxidx.x&&htime.y<gcfg->maxidx.y&&htime.z<gcfg->maxidx.z){
                           if(media[(int)(htime.z*gcfg->dimlen.y+htime.y*gcfg->dimlen.x+htime.x)]!=mediaidold){ //this is an air voxel

                               GPUDEBUG((" second try failed: [%.1f %.1f,%.1f] %d (%.1f %.1f %.1f)\n",htime.x,htime.y,htime.z,
                                   media[(int)(htime.z*gcfg->dimlen.y+htime.y*gcfg->dimlen.x+htime.x)], gcfg->maxidx.x, gcfg->maxidx.y,gcfg->maxidx.z));

                               /*to compute the remaining interface, we used the following fact to accelerate: 
                                 if there exist 3 intersections, photon must pass x/y/z interface exactly once,
                                 we solve the coeff of the following equation to find the last interface:
                                    a*1+b*2+c=3
       	       	       	       	    a*1+b*3+c=2 -> [a b c]=[-1 -1 6], this will give the remaining interface id
       	       	       	       	    a*2+b*3+c=1
                               */
                               flipdir=-tmp1-flipdir+6.f;
                           }
                       }
                     }
                  }
                }
              }

              prop=gproperty[mediaid];

              GPUDEBUG(("->ID%d J%d C%d tlen %e flip %d %.1f!=%.1f dir=%f %f %f pos=%f %f %f\n",idx,(int)v.w,
                  (int)f.w,f.y, (int)flipdir, n1,prop.z,v.x,v.y,v.z,p.x,p.y,p.z));

              //recycled some old register variables to save memory
	      //if hit boundary within the time window and is n-mismatched, rebound

              if(gcfg->doreflect&&f.y<gcfg->tmax&&f.y<gcfg->twin1&& flipdir>0.f && n1!=prop.z&&p.w>gcfg->minenergy){
                  tmp0=n1*n1;
                  tmp1=prop.z*prop.z;
                  if(flipdir>=3.f) { //flip in z axis
                     cphi=fabs(v.z);
                     sphi=v.x*v.x+v.y*v.y;
                     v.z=-v.z;
                  }else if(flipdir>=2.f){ //flip in y axis
                     cphi=fabs(v.y);
       	       	     sphi=v.x*v.x+v.z*v.z;
                     v.y=-v.y;
                  }else if(flipdir>=1.f){ //flip in x axis
                     cphi=fabs(v.x);                //cos(si)
                     sphi=v.y*v.y+v.z*v.z; //sin(si)^2
                     v.x=-v.x;
                  }
                  len=1.f-tmp0/tmp1*sphi;   //1-[n1/n2*sin(si)]^2
	          GPUDEBUG((" ref len=%f %f+%f=%f w=%f\n",len,cphi,sphi,cphi*cphi+sphi,p.w));

                  if(len>0.f) {
                     ctheta=tmp0*cphi*cphi+tmp1*len;
                     stheta=2.f*n1*prop.z*cphi*sqrt(len);
                     Rtotal=(ctheta-stheta)/(ctheta+stheta);
       	       	     ctheta=tmp1*cphi*cphi+tmp0*len;
       	       	     Rtotal=(Rtotal+(ctheta-stheta)/(ctheta+stheta))*0.5f;
	             GPUDEBUG(("  dir=%f %f %f htime=%f %f %f Rs=%f\n",v.x,v.y,v.z,htime.x,htime.y,htime.z,Rtotal));
	             GPUDEBUG(("  ID%d J%d C%d flip=%3f (%d %d) cphi=%f sphi=%f p=%f %f %f p0=%f %f %f\n",
                         idx,(int)v.w,(int)f.w,
	                 flipdir,idx1dold,idx1d,cphi,sphi,p.x,p.y,p.z,p0.x,p0.y,p0.z));
                  }
	          if(Rtotal<1.f && rand_next_reflect(t)>Rtotal){ // do transmission
                        if(mediaid==0){ // transmission to external boundary
		    	    launchnewphoton(&p,&v,&f,&prop,&idx1d,&mediaid,(mediaidold & DET_MASK),
			        ppath,&energyloss,&energyabsorbed,n_det,detectedphoton,gproperty,gdetpos,gcfg);
			    continue;
			}
			tmp0=n1/prop.z;
                	if(flipdir>=3.f) { //transmit through z plane
                	   v.x=tmp0*v.x;
                	   v.y=tmp0*v.y;
                	}else if(flipdir>=2.f){ //transmit through y plane
                	   v.x=tmp0*v.x;
                	   v.z=tmp0*v.z;
                	}else if(flipdir>=1.f){ //transmit through x plane
                	   v.y=tmp0*v.y;
                	   v.z=tmp0*v.z;
                	}
			tmp0=rsqrt(v.x*v.x+v.y*v.y+v.z*v.z);
			v.x=v.x*tmp0;
			v.y=v.y*tmp0;
			v.z=v.z*tmp0;
		  }else{ //do reflection
                	if(flipdir>=3.f) { //flip in z axis
                	   v.z=-v.z;
                	}else if(flipdir>=2.f){ //flip in y axis
                	   v.y=-v.y;
                	}else if(flipdir>=1.f){ //flip in x axis
                	   v.x=-v.x;
                	}
                        p=p0;   //move back
                	idx1d=idx1dold;
		 	mediaid=(media[idx1d] & MED_MASK);
        	  	*((float4*)(&prop))=gproperty[mediaid];
                  	n1=prop.z;
		  }
              }else{  // launch a new photon
#ifdef MCX_CPU_ONLY
		  if(stopsign[0]) break;
#endif
		  launchnewphoton(&p,&v,&f,&prop,&idx1d,&mediaid,(mediaidold & DET_MASK),ppath,
		      &energyloss,&energyabsorbed,n_det,detectedphoton,gproperty,gdetpos,gcfg);
		  continue;
              }
	  }else if(f.y>=f.z){
             GPUDEBUG(("field add to %d->%f(%d)  t(%e)>t0(%e)\n",idx1d,p.w,(int)f.w,f.y,f.z));
             // if t is within the time window, which spans cfg->maxgate*cfg->tstep wide
             if(gcfg->save2pt&&f.y>=gcfg->twin0 & f.y<gcfg->twin1){
#ifdef TEST_RACING
                  // enable TEST_RACING to determine how many missing accumulations due to race
                  if( (p.x-gcfg->ps.x)*(p.x-gcfg->ps.x)+(p.y-gcfg->ps.y)*(p.y-gcfg->ps.y)+(p.z-gcfg->ps.z)*(p.z-gcfg->ps.z)>gcfg->skipradius2) {
                      field[idx1d+(int)(floor((f.y-gcfg->twin0)*gcfg->Rtstep))*gcfg->dimlen.z]+=1.f;
		      cc++;
                  }
#else
  #ifndef USE_ATOMIC
                  // set gcfg->skipradius2 to only start depositing energy when dist^2>gcfg->skipradius2 
                  if(gcfg->skipradius2>EPS){
                      if((p.x-gcfg->ps.x)*(p.x-gcfg->ps.x)+(p.y-gcfg->ps.y)*(p.y-gcfg->ps.y)+(p.z-gcfg->ps.z)*(p.z-gcfg->ps.z)>gcfg->skipradius2){
                          field[idx1d+(int)(floor((f.y-gcfg->twin0)*gcfg->Rtstep))*gcfg->dimlen.z]+=p.w;
                      }else{
                          accumweight+=p.w*prop.x; // weight*absorption
                      }
                  }else{
                      field[idx1d+(int)(floor((f.y-gcfg->twin0)*gcfg->Rtstep))*gcfg->dimlen.z]+=p.w;
                  }
  #else
                  // ifndef CUDA_NO_SM_11_ATOMIC_INTRINSICS
//		  atomicFloatAdd(& field[idx1d+(int)(floor((f.y-gcfg->twin0)*gcfg->Rtstep))*gcfg->dimlen.z], p.w);
  #endif
#endif
	     }
             f.z+=gcfg->minaccumtime; // fluence is a temporal-integration
	  }
     }
     // accumweight saves the total absorbed energy in the sphere r<sradius.
     // in non-atomic mode, accumweight is more accurate than saving to the grid
     // as it is not influenced by race conditions.
     // now I borrow f.z to pass this value back

     f.z=accumweight;

     genergy[idx<<1]=energyloss;
     genergy[(idx<<1)+1]=energyabsorbed;

#ifdef TEST_RACING
     n_seed[idx]=cc;
#endif
     n_pos[idx]=p;
     n_dir[idx]=v;
     n_len[idx]=f;
}

