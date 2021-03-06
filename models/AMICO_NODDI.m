classdef AMICO_NODDI

properties
    id, name                % id and name of the model
    dPar                    % parallel diffusivity  [units of mm^2/s]
    dIso                    % isotropic diffusivity [units of mm^2/s]
    IC_VFs                  % volume fractions of the intra-cellular space
    IC_ODs                  % dispersions of the intra-cellular space
    OUTPUT_names            % suffix of the output maps
    OUTPUT_descriptions     % description of the output maps
end


methods

    % =================================
    % Setup the parameters of the model
    % =================================
	function obj = AMICO_NODDI()
        global CONFIG

        % set the parameters of the model
        obj.id        = 'NODDI';
        obj.name      = 'NODDI';
        obj.dPar      = 1.7 * 1E-3;
        obj.dIso      = 3.0 * 1E-3;
    	obj.IC_VFs    = linspace(0.1, 0.99,12);
		obj.IC_ODs    = [0.03, 0.06, linspace(0.09,0.99,10)];
        
        obj.OUTPUT_names        = { 'ICVF', 'OD', 'ISOVF' };
        obj.OUTPUT_descriptions = {'Intra-cellular volume fraction', 'Orientation dispersion', 'Isotropic volume fraction'};


        % set the parameters to fit it
        CONFIG.OPTIMIZATION.SPAMS_param.mode    = 2;
        CONFIG.OPTIMIZATION.SPAMS_param.pos     = true;
        CONFIG.OPTIMIZATION.SPAMS_param.lambda  = 5e-1; % l1 regularization
        CONFIG.OPTIMIZATION.SPAMS_param.lambda2 = 1e-3; % l2 regularization
    end


    % ==================================================================
    % Generate high-resolution kernels and rotate them in harmonic space
    % ==================================================================
    function GenerateKernels( obj, ATOMS_path, schemeHR, AUX, idx_IN, idx_OUT )
        global CONFIG AMICO_data_path

        % Configure NODDI toolbox
        % =======================
        noddi = MakeModel( 'WatsonSHStickTortIsoV_B0' );

        % set the parallel/isotropic diffusivity from AMICO's configuration (accounting for units difference)
        dPar = CONFIG.model.dPar * 1E-6;
        dIso = CONFIG.model.dIso * 1E-6;
        noddi.GS.fixedvals(2) = dPar;
        noddi.GD.fixedvals(2) = dPar;
        noddi.GS.fixedvals(5) = dIso; 
        noddi.GD.fixedvals(5) = dIso;

        protocolHR = obj.Scheme2noddi( schemeHR );
   
        % Coupled compartments
        % ====================
        idx = 1;
        for ii = 1:numel(obj.IC_ODs)
            kappa = 1 ./ tan(obj.IC_ODs(ii)*pi/2);
            signal_ic = SynthMeasWatsonSHCylNeuman_PGSE( [dPar 0 kappa], protocolHR.grad_dirs, protocolHR.G', protocolHR.delta', protocolHR.smalldel', [0;0;1], 0 );

            for jj = 1:numel(obj.IC_VFs)
                TIME = tic();
                fprintf( '\t\t- A_%03d... ', idx );

                % generate
                v_ic = obj.IC_VFs(jj);
                dPerp = dPar * (1 - v_ic);
                signal_ec = SynthMeasWatsonHinderedDiffusion_PGSE( [dPar dPerp kappa], protocolHR.grad_dirs, protocolHR.G', protocolHR.delta', protocolHR.smalldel', [0;0;1] );
                signal = v_ic*signal_ic + (1-v_ic)*signal_ec;

                % rotate and save
                lm = AMICO_RotateKernel( signal, AUX, idx_IN, idx_OUT, false );
                save( fullfile( ATOMS_path, sprintf('A_%03d.mat',idx) ), '-v6', 'lm' )

                idx = idx+1;
                fprintf( '[%.1f seconds]\n', toc(TIME) );
            end
        end
        
        
        % Isotropic
        % =========
        TIME = tic();
        fprintf( '\t\t- A_%03d... ', idx );

        % generate
        signal = SynthMeasIsoGPD( dIso, protocolHR );

        % resample and save
        lm = AMICO_RotateKernel( signal, AUX, idx_IN, idx_OUT, true );
        save( fullfile( ATOMS_path, sprintf('A_%03d.mat',idx) ), '-v6', 'lm' )

        idx = idx + 1;
        fprintf( '[%.1f seconds]\n', toc(TIME) );

    end


    % ==============================================
    % Project kernels from harmonic to subject space
    % ==============================================
    function ResampleKernels( obj, ATOMS_path, idx_OUT, Ylm_OUT )
        global CONFIG AMICO_data_path KERNELS

        % Setup the KERNELS structure
        % ===========================
        KERNELS = {};
        KERNELS.nS      = CONFIG.scheme.nS;
        KERNELS.nA      = numel(obj.IC_VFs) * numel(obj.IC_ODs) + 1; % number of atoms
        KERNELS.A       = zeros( [KERNELS.nS KERNELS.nA-1 181 181], 'single' );
    	KERNELS.A_kappa = zeros( 1, KERNELS.nA-1, 'single' );
        KERNELS.A_icvf  = zeros( 1, KERNELS.nA-1, 'single' );;
        KERNELS.Aiso    = zeros( [KERNELS.nS 1], 'single' );
        KERNELS.Aiso_d  = NaN;


        % Coupled atoms
        % =============
        idx = 1;
        for ii = 1:numel(obj.IC_ODs)
        for jj = 1:numel(obj.IC_VFs)
            TIME = tic();
            fprintf( '\t- A_%03d...  ', idx );

            load( fullfile( ATOMS_path, sprintf('A_%03d.mat',idx) ), 'lm' );
            KERNELS.A(:,idx,:,:) = AMICO_ResampleKernel( lm, idx_OUT, Ylm_OUT, false );
            KERNELS.A_kappa(idx) = 1 ./ tan(obj.IC_ODs(ii)*pi/2);
            KERNELS.A_icvf(idx)  = obj.IC_VFs(jj);
            idx = idx + 1;

            fprintf( '[%.1f seconds]\n', toc(TIME) );
        end
        end


        % Isotropic
        % =========
        TIME = tic();
        fprintf( '\t- A_%03d...  ', idx );

        load( fullfile( ATOMS_path, sprintf('A_%03d.mat',idx) ), 'lm' );
        KERNELS.Aiso   = AMICO_ResampleKernel( lm, idx_OUT, Ylm_OUT, true );
        KERNELS.Aiso_d = obj.dIso;
        idx = idx + 1;

        fprintf( '[%.1f seconds]\n', toc(TIME) );

    end


    % ===========================
    % Fit the model to each voxel
    % ===========================
    function [DIRs, MAPs] = Fit( obj )
        global CONFIG
        global niiSIGNAL niiMASK
        global KERNELS bMATRIX

        % setup the output files
        MAPs         = zeros( [CONFIG.dim(1:3) numel(obj.OUTPUT_names)], 'single' );
        DIRs         = zeros( [CONFIG.dim(1:3) 3], 'single' );        

        % precompute norms of coupled atoms (for the l1 minimization)
        A = double( KERNELS.A(CONFIG.scheme.dwi_idx,:,1,1) );
        A_norm = repmat( 1./sqrt( sum(A.^2) ), [size(A,1),1] );


        fprintf( '\n-> Fitting "%s" model to data:\n', obj.name );
        TIME = tic;
        for iz = 1:niiSIGNAL.hdr.dime.dim(4)
        for iy = 1:niiSIGNAL.hdr.dime.dim(3)
        for ix = 1:niiSIGNAL.hdr.dime.dim(2)
            if niiMASK.img(ix,iy,iz)==0, continue, end

            % read the signal
            b0 = mean( squeeze( niiSIGNAL.img(ix,iy,iz,CONFIG.scheme.b0_idx) ) );
            if ( b0 < 1e-3 ), continue, end
            y = double( squeeze( niiSIGNAL.img(ix,iy,iz,:) ) ./ ( b0 + eps ) );
            y( y < 0 ) = 0; % [NOTE] this should not happen!

            % find the MAIN DIFFUSION DIRECTION using DTI
            [ ~, ~, V ] = AMICO_FitTensor( y, bMATRIX );
            Vt = V(:,1);
            if ( Vt(2)<0 ), Vt = -Vt; end

            % build the DICTIONARY
            [ i1, i2 ] = AMICO_Dir2idx( Vt );
            A = double( [ KERNELS.A(CONFIG.scheme.dwi_idx,:,i1,i2) KERNELS.Aiso(CONFIG.scheme.dwi_idx) ] );

            % fit AMICO
            y = y(CONFIG.scheme.dwi_idx);
            yy = [ 1 ; y ];
            AA = [ ones(1,size(A,2)) ; A ];

            % estimate CSF partial volume and remove it
            x = lsqnonneg( AA, yy, CONFIG.OPTIMIZATION.LS_param );
            y = y - x(end)*A(:,end);

            % estimate IC and EC compartments and promote sparsity
            An = A(:,1:end-1) .* A_norm;
            x = full( mexLasso( y, An, CONFIG.OPTIMIZATION.SPAMS_param ) );

            % debias
            idx = x>0;
            idx(end+1) = true;
            x(idx) = lsqnonneg( AA(:,idx), yy, CONFIG.OPTIMIZATION.LS_param );

            % STORE results	
            DIRs(ix,iy,iz,:) = Vt;

            xx =  x(1:end-1);
            xx = xx ./ ( sum(xx) + eps );
            f1 = KERNELS.A_icvf * xx;
            f2 = (1-KERNELS.A_icvf) * xx;
            MAPs(ix,iy,iz,1) = f1 / (f1+f2+eps);

            kappa = KERNELS.A_kappa * xx;
            MAPs(ix,iy,iz,2) = 2/pi * atan2(1,kappa);

            MAPs(ix,iy,iz,3) = x(end);
        end
        end
        end
        TIME = toc(TIME);
        fprintf( '   [ %.0fh %.0fm %.0fs ]\n', floor(TIME/3600), floor(mod(TIME/60,60)), mod(TIME,60) )
    end


    % ===========================================
    % Create NODDI protocol structure from scheme
    % ===========================================
    function [ protocol ] = Scheme2noddi( obj, scheme )

        protocol = [];
        protocol.pulseseq = 'PGSE';
        protocol.schemetype = 'multishellfixedG';
        protocol.teststrategy = 'fixed';

        % load bval
        bval = scheme.b;

        % set total number of measurements
        protocol.totalmeas = length(bval);

        % set the b=0 indices
        protocol.b0_Indices = find(bval==0);
        protocol.numZeros = length(protocol.b0_Indices);

        % find the unique non-zero b-values
        B = unique(bval(bval>0));

        % set the number of shells
        protocol.M = length(B);
        for i=1:length(B)
            protocol.N(i) = length(find(bval==B(i)));
        end

        % maximum b-value in the s/mm^2 unit
        maxB = max(B);

        % set maximum G = 40 mT/m
        Gmax = 0.04;

        % set smalldel and delta and G
        GAMMA = 2.675987E8;
        tmp = nthroot(3*maxB*10^6/(2*GAMMA^2*Gmax^2),3);
        for i = 1:length(B)
            protocol.udelta(i)    = tmp;
            protocol.usmalldel(i) = tmp;
            protocol.uG(i)        = sqrt(B(i)/maxB)*Gmax;
        end

        protocol.delta    = zeros(size(bval))';
        protocol.smalldel = zeros(size(bval))';
        protocol.G        = zeros(size(bval))';

        for i=1:length(B)
            tmp = find(bval==B(i));
            for j=1:length(tmp)
                protocol.delta(tmp(j)) = protocol.udelta(i);
                protocol.smalldel(tmp(j)) = protocol.usmalldel(i);
                protocol.G(tmp(j)) = protocol.uG(i);
            end
        end

        % load bvec
        protocol.grad_dirs = scheme.camino(:,1:3);

        % make the gradient directions for b=0's [1 0 0]
        for i=1:length(protocol.b0_Indices)
            protocol.grad_dirs(protocol.b0_Indices(i),:) = [1 0 0];
        end

        % make sure the gradient directions are unit vectors
        for i=1:protocol.totalmeas
            protocol.grad_dirs(i,:) = protocol.grad_dirs(i,:)/norm(protocol.grad_dirs(i,:));
        end
    end
 
end

end
