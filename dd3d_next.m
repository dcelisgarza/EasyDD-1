% %Dislocation Dynamics simulation in 3-dimension
% % Features:
% % mixed boundary conditions cantilever.
% % linear mobility law (mobfcc0,mobfcc1)
% % N^2 interaction (no neighbor list, no fast multipole)
%
% %Data structure:
% %NMAX:    maximum number of nodes (including disabled ones)
% %LINKMAX: maximum number of links (including disabled ones)
% %rn: (NMAX,4) array of nodal positions (last column is flag: -1 means disabled)
% %vn: (NMAX,3) array of nodal velocities
% %fn: (NMAX,3) array of nodal forces
% %links: (LINKMAX,8) array of links (id1,id2,bx,by,bz,nx,ny,nz)
%
% compile the c source code for seg-seg force evaluation and makes a dynamic linked library
%  disp('Compiling MEX files');
%  mex -v COPTIMFLAGS="-O3 -Oy -DNDEBUG" SegSegForcesMex.c
%  mex -v COPTIMFLAGS="-O3 -Oy -DNDEBUG" StressDueToSegs.c
%  mex -v COPTIMFLAGS="-O3 -Oy -DNDEBUG" UtildaMex.c
%  mex -v COPTIMFLAGS="-O3 -Oy -DNDEBUG" mindistcalcmex.c
%  mex -v COPTIMFLAGS="-O3 -Oy -DNDEBUG"  CollisionCheckerMex.c
%  mex -v COPTIMFLAGS="-O3 -Oy -DNDEBUG" mobbcc1mex.c
%  mex -v COPTIMFLAGS="-O3 -Oy -DNDEBUG" displacementmex_et.c
%  mex -v COPTIMFLAGS="-O3 -Oy -DNDEBUG" CreateInputMex.c %CollisionMarielle
%  mex -v COPTIMFLAGS="-O3 -Oy -DNDEBUG" CollisionCheckerMexMariellebis.c %CollisionMarielle
%  mex -v COPTIMFLAGS="-O3 -Oy -DNDEBUG" ./nodalForce/nodal_surface_force_linear_rectangle_mex.c
%  mexcuda -v COMPFLAGS="-Xptxas -v -arch=compute_60 -code=sm_60 -use_fast_math" ./nodalForce/nodal_surface_force_linear_rectangle_mex_cuda.cu
%   disp('Done!');
%  default value if run by itself (e.g. not through "rundd3d")
%  cleanup the empty node and link entries at the end of the initial data structures
[rn,links]=cleanupnodes(rn,links);

% genererate the connectivity list from the list of links
disp('Initiliazing connectivity list. Please wait.');
[connectivity,linksinconnect]=genconnectivity(rn,links,maxconnections);

consistencycheck(rn,links,connectivity,linksinconnect);
disp('Consistencycheck : Done!');

%construct stiffeness matrix K and pre-compute L,U decompositions.
disp('Constructing stiffness matrix K and precomputing L,U decompositions. Please wait.');
[vertices,B,xnodes,mno,nc,n,D,kg,K,L,U,Sleft,Sright,Stop,Sbot,...
    Sfront,Sback,gammat,gammau,gammaMixed,fixedDofs,freeDofs,...
    w,h,d,my,mz,mel] = finiteElement3D(dx,dy,dz,mx,MU,NU,loading);

%% Addition by Daniel Celis Garza 12/19/2017.
% Precomputing variables needed to couple tractions induced by dislocations
% to FEM. Generate the list of planes to be extracted. The FEM coupler is
% hardcoded so that the min(x) yz-plane does not have traction boundary
% conditions.
if(~exist('a_trac','var'))
    a_trac=0;
end
if (~exist('use_gpu', 'var'))
    use_gpu = 0;
end
if a_trac ~= 0
    f_hat = zeros(3*mno, 1);
    para_tol = dx/1e7;

    planes = (1:1:6)';
    [x3x6_lbl, x3x6, n_se] = extract_surface_nodes(xnodes, nc, [mx;my;mz],...
        planes, 4);
    gamma_dln = [gammat(:,1); gammaMixed(:,1)];
    [f_dln_node, f_dln_se,...
        f_dln, idxi, n_nodes_t] = nodal_force_map(x3x6_lbl, gamma_dln, 4, n_se, mno);
    tolerance = dx/10^7;
    % Parallel CUDA C flags.
    if use_gpu == 1
        % Provide a default number of threads in case none is given.
        if ~exist('n_threads', 'var')
            n_threads = 256;
        end %if
        % Provide a default parallelisaion scheme in case none is given.
        if ~exist('para_scheme', 'var')
            % Parallelise over dislocations.
            para_scheme = 1;
        end %if
    else
        n_threads = 0;
        para_scheme = 0;
    end %if

    gamma_disp = [gammau; gammaMixed];
end

disp('Done! Initializing simulation.');

global USE_GPU;
USE_GPU=0; %0 if CPU only.

if (USE_GPU==1)
    disp('Going to use GPU as well...'); % setenv('PATH', [getenv('PATH') ';C:\Program Files (x86)\Microsoft Visual Studio 11.0\VC\bin\amd64']);
    system('nvcc -ptx -m64 -arch sm_35 SegForceNBodyCUDADoublePrecision.cu');
end


%Use Delaunay triangulation to create surface mesh, used for visualisation

%and for dislocation remeshing algorithm.
[TriangleCentroids,TriangleNormals,tri,Xb] = ...
    MeshSurfaceTriangulation(xnodes,Stop,Sbot,Sfront,Sback,Sleft,Sright,gammaMixed);
%Remesh considering surfaces in case input file incorrect.
%disp('Remeshing...');
[rn,links,connectivity,linksinconnect]=remesh_surf(rn,links,connectivity,linksinconnect,vertices,TriangleCentroids,TriangleNormals);

%plot dislocation structure
% figure(1);
% plotHandle = plotnodes(rn,links,plim,vertices); view(viewangle);
% drawnow

% data=zeros(totalsteps,1);
if(~exist('dt','var'))
    dt=dt0;
end
dt=min(dt,dt0);
plotCounter=1;
close all

Fend=zeros(1e6,1); fend=[];
U_bar=zeros(1e6,1); Ubar=[];
t=zeros(1e6,1); simTime=0;
%%
gamma=[gammau;gammaMixed];
utilda_0=zeros(3*mno,1);
gn = gamma(:,1);
[Ux, Uy, Uz] = Utilda_bb3(rn,links,gn,NU,xnodes,dx,dy,dz,mx,my,mz);

utilda_0(3*gn -2) = Ux;
utilda_0(3*gn -1) = Uy;
utilda_0(3*gn   ) = Uz;
%%
while simTime < totalSimTime

    % frame recording
    %     intSimTime=intSimTime+dt;
    %     if intSimTime > dtplot && doplot == 1
    %         plotHandle=plotnodes(rn,links,plim,vertices);view(viewangle);
    %         %plotHandle=schematicplot2(rn,links,vertices,U_bar,Fend,amag,dx,totalSimTime);
    %         plotCounter=plotCounter+1;
    %         plotCounterString=num2str(plotCounter,'%03d');
    %         %saveas(plotHandle,[pwd '/Images/' plotCounterString], 'png')
    %         %save([pwd '/Data/' plotCounterString],'rn','links','fend','Ubar','simTime');
    %         %plotHandle=plotnodes(rn,links,plim,vertices);view(viewangle);
    %         plotnodes(rn,links,plim,vertices);view(viewangle);
    %         zlim([-100 100])
    %         xlim([-100 100])
    %         ylim([-100 100])
    %         intSimTime=intSimTime-dtplot;
    %     end

    %DDD+FEM coupling
    if a_trac == 0
        [uhat,fend,Ubar] = FEMcoupler(rn,links,a,MU,NU,xnodes,mno,kg,L,U,...
            gammau,gammat,gammaMixed,fixedDofs,freeDofs,dx,dy,dz,simTime,mx,my,mz,utilda_0);
    else
        [uhat,fend,Ubar] = analytic_FEMcoupler(rn,links,a,MU,NU,xnodes,mno,kg,L,U,...
            gamma_disp, gammat, gammaMixed, fixedDofs,freeDofs,dx,dy,dz,simTime,mx,my,mz,utilda_0,...
            gamma_dln, x3x6, 4, n_nodes_t, n_se, idxi, ...
            f_dln_node, f_dln_se, f_dln, f_hat, use_gpu, n_threads, para_scheme, para_tol);
    end
    Fend(curstep+1) = fend;
    U_bar(curstep+1) = Ubar;
    t(curstep+1) = simTime;

    fprintf('fend = %d, Ubar = %d, simTime = %d \n',fend,Ubar,simTime);

    %     if (dovirtmesh)
    %         %remeshing virtual dislocation structures
    %         %[rn,links,connectivity,linksinconnect]=remesh_surf(rn,links,connectivity,linksinconnect,vertices,TriangleCentroids,TriangleNormals);
    %         %[rn,links,connectivity,linksinconnect] = virtualmeshcoarsen2(rn,links,maxconnections,10*lmin);
    %     end

    %integrating equation of motion
    [rnnew,vn,dt,fn,fseg]=feval(integrator,rn,dt,dt0,MU,NU,a,Ec,links,connectivity,...
        rmax,rntol,mobility,vertices,uhat,nc,xnodes,D,mx,mz,w,h,d);
    % plastic strain and plastic spin calculations
    [ep_inc,wp_inc]=calcplasticstrainincrement(rnnew,rn,links,(2*plim)^3);

    if(mod(curstep,printfreq)==0) && not(isempty(vn))
        fprintf('step%3d dt=%e v%d=(%e,%e,%e) \n',...
            curstep,dt,printnode,vn(printnode,1),vn(printnode,2),vn(printnode,3));
        close all;
        save restart_temp
    elseif (mod(curstep,printfreq)==0)
        fprintf('step%3d dt=%e v%d=(%e,%e,%e) \n',...
            curstep,dt,printnode);
    end

    if(mod(curstep,plotfreq)==0)
        plotnodes(rn,links,plim,vertices);
        view(viewangle);
        %schematicplot2(rn,links,vertices,U_bar,Fend,amag,dx,totalSimTime);
        drawnow
        pause(0.01);
        %
        %         figure(2);
        %          clf
        %          plot(U_bar*bmag,-Fend*bmag^2*mumag)
        %          pause(0.01);
    end

    [planeindex]=outofplanecheck(rn, links);

    rnnew=[rnnew(:,1:3) vn rnnew(:,4)];
    linksnew=links;
    connectivitynew=connectivity;
    linksinconnectnew=linksinconnect;
    fsegnew=fseg;

    if (doremesh) %do virtual re-meshing first
        %remeshing virtual dislocation structures
        if (dovirtmesh)
            %[rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew]=virtualmeshcoarsen_mex(rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew,DIST_SOURCE*0.49,dx,MU,NU,a,Ec);
            %[rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew]=virtualmeshcoarsen(rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew,DIST_SOURCE*0.49,dx,MU,NU,a,Ec);
            [rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew]=virtualmeshcoarsen3(rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew,MU,NU,a,Ec,dx,dy,dz);
            %[rnnew,linksnew,connectivitynew,linksinconnectnew] = virtualmeshcoarsen2(rnnew,linksnew,maxconnections,10*lmin);
        end
        %remeshing internal dislocation structures
        [rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew]=remesh_all(rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew,lmin,lmax,areamin,areamax,MU,NU,a,Ec,mobility,doremesh,dovirtmesh,vertices,...
            uhat,nc,xnodes,D,mx,mz,w,h,d,TriangleCentroids,TriangleNormals);
    end

    %save restart.mat
    if (docollision)
        s1_old=0;
        s2_old=0;
        %collision detection and handling

        %COLLISION GPU / GPUPLUS  Marielle  + CollisionCheckerMexMarielle
        %it requires a GPU device
        %it requires CollisionCheckerMexMarielle, collisionGPUplus (or collision GPU), mindistcalcGPU1, mindistcalcGPU2,CreateInputMex
        colliding_segments=1;
        while colliding_segments==1
            [colliding_segments,n1s1,n2s1,n1s2,n2s2,floop,s1,s2,segpair]=CollisionCheckerMexMariellebis(rnnew(:,1),rnnew(:,2),rnnew(:,3),rnnew(:,end),...
                rnnew(:,4),rnnew(:,5),rnnew(:,6),linksnew(:,1),linksnew(:,2),connectivitynew,rann);


            %                   if colliding_segments == 1 %scan and update dislocation structure.
            %                         reset(gpuDevice)
            %                         [rnnew,linksnew,~,~,fsegnew]=...
            %                         collisionGPUplus(rnnew,linksnew,connectivitynew,linksinconnectnew,...
            %                         fsegnew,rann,MU,NU,a,Ec,mobility,vertices,uhat,nc,xnodes,D,mx,mz,w,h,d,floop,n1s1,n2s1,n1s2,n2s2,s1,s2,segpair);
            %                   end


            %              INTIAL COLLISION
            %              [colliding_segments]=CollisionCheckerMex(rnnew(:,1),rnnew(:,2),rnnew(:,3),rnnew(:,end),...
            %              rnnew(:,4),rnnew(:,5),rnnew(:,6),linksnew(:,1),linksnew(:,2),connectivitynew,rann);
            if colliding_segments == 1 %scan and update dislocation structure.
                if floop == 1
                    fprintf("Step %d. Unconnected links found. Links %d and %d are colliding.\n", curstep, s1, s2)
                elseif floop == 2
                    fprintf("Step %d. Links %d and %d colliding by hinge condition.\n", curstep, s1, s2)
                end

                %                 [rnnew,linksnew,~,~,fsegnew]=...
                %                 collision(rnnew,linksnew,connectivitynew,linksinconnectnew,...
                %                 fsegnew,rann,MU,NU,a,Ec,mobility,vertices,uhat,nc,xnodes,D,mx,mz,w,h,d);

%                 fprintf(' Segment %d and segment %d are colliding\n',s1,s2);
                if colliding_segments==1
                    [rnnew,linksnew,~,~,fsegnew,colliding_segments]=collision_basic(rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew,rann,MU,NU,a,Ec,mobility,vertices,...
                        uhat,nc,xnodes,D,mx,mz,w,h,d,floop,n1s1,n2s1,n1s2,n2s2,s1,s2,segpair);

                    %removing links with effective zero Burgers vectors
                    [rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew] = cleanupsegments(rnnew,linksnew,fsegnew);
                    
                    [rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew]=remesh_all(rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew,lmin,lmax,areamin,areamax,MU,NU,a,Ec,mobility,doremesh,0,vertices,...
        uhat,nc,xnodes,D,mx,mz,w,h,d,TriangleCentroids,TriangleNormals);
                    if (doseparation)
                        if max(connectivitynew(:,1))>3
                            %spliting of nodes with 4 or more connections
                            [rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew]=...
                                separation(rnnew,linksnew,connectivitynew,linksinconnectnew,...
                                fsegnew,mobility,MU,NU,a,Ec,2*rann,vertices,uhat,nc,xnodes,D,mx,mz,w,h,d);
                        end
                    end
                end
%                 [rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew]=remesh_all(rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew,lmin,lmax,areamin,areamax,MU,NU,a,Ec,mobility,doremesh,0,vertices,...
%         uhat,nc,xnodes,D,mx,mz,w,h,d,TriangleCentroids,TriangleNormals);
            end
        end
    end

    %find blockading fixed nodes and allow code to deal with them
    for i=1:size(rnnew,1)
        if rnnew(i,end)~=7
            continue
        end
        if connectivitynew(i,1)>7
            rnnew(i,end)=0;
        end
    end

    if (doseparation)
        if max(connectivitynew(:,1))>3
            %spliting of nodes with 4 or more connections
            [rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew]=...
                separation(rnnew,linksnew,connectivitynew,linksinconnectnew,...
                fsegnew,mobility,MU,NU,a,Ec,2*rann,vertices,uhat,nc,xnodes,D,mx,mz,w,h,d);
        end
    end

    [rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew]=remesh_all(rnnew,linksnew,connectivitynew,linksinconnectnew,fsegnew,lmin,lmax,areamin,areamax,MU,NU,a,Ec,mobility,doremesh,0,vertices,...
        uhat,nc,xnodes,D,mx,mz,w,h,d,TriangleCentroids,TriangleNormals);

    rn=[rnnew(:,1:3) rnnew(:,7)];
    vn=rnnew(:,4:6);
    links=linksnew;
    connectivity=connectivitynew;
    linksinconnect=linksinconnectnew;
    fseg=fsegnew;

    %store run time information
    %time step
    curstep = curstep + 1;
    %data(curstep,1)=dt;
    simTime = simTime+dt;

    %    save restart;
    %     if all(rn(:,4)==67) %no more real segments, stop simulation
    %         disp('Dislocation-free real domain. Only virtual segments remain!');
    %         disp('Computing distorted mesh. Please wait...');
    %         [utilda]=visualise(rn,links,NU,D,mx,my,mz,mel,mno,xnodes,nc,...
    %             dx,dy,dz,w,h,d,vertices,uhat);
    %         return;
    %     end

end

save restart;
disp('completed')

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
