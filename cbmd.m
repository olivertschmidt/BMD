function [L,P,f,idx,T] = cbmd(X,varargin)
% CBMD Cross-Bispectreal Mode Decomposition
%
% CBMD has the same inputs and outputs as BMD, but X must contain all three
% variables Q, R, and S to be cross-correlated. The second index (after
% time) must be the variable index, such that X(:,1,...) = Q,  X(:,2,...) =
% R, and  X(:,3,...) = S. If a long-time mean is provided via OPTS.mean,
% then the first index of OPTS.mean must also be the variable index.
%
%  [L,P,F,IDX,T] = CBMD(...) returns in T the net energy transfer into or
%  out of f3
%
%  [L,P,F,IDX,T] = CBMD(X,WINDOW,WEIGHT,NOVERLAP,DT,OPTS) specifies 
%                   additional options:
%  OPTS.s_idx       column vector of variable indices to specify form of
%                   quadratic nonlinear term; has to be specified along
%                   with OPTS.qr_idx
%  OPTS.qr_idx      array specifying variable indices of
%                   products q*r; colums are alternating variable indices
%                   for q snd r; one row per variable in s required
%
%  References:
%   [1] Schmidt, O. T., Bispectral mode decomposition of nonlinear flows,
%       Nonlinear Dynamics, 2020
%       DOI 10.1007/s11071-020-06037-z
%       https://rdcu.be/cbg3D
%
% O. T. Schmidt (oschmidt@ucsd.edu)
% Last revision: 17-Aug-2023

single_prec     = false;
if nargin==6
    opts = varargin{5};
    if ~isfield(opts,'regions')
        opts.regions    = [1 2];
    end
    if isfield(opts,'precision')
        if strncmpi(opts.precision,'single',6)
            single_prec = true;
        end
    end
else
    opts.regions = [1 2];
end

% get problem dimensions
dim     = size(X);
nt      = dim(1);
nVar    = dim(2);

% form of quadratic nonlinearity
if ~(isfield(opts,'s_idx')&&isfield(opts,'qr_idx'))
    opts.s_idx      = 1; 
    opts.qr_idx     = [2 3];
end

nx      = prod(dim(3:end));

% get default spectral estimation parameters and options
[window,weight,nOvlp,dt,nDFT,nBlks] = parser(nt,nx,varargin{:});

% determine correction for FFT window gain
winWeight   = 1/mean(window);

% optimizers for x*Ax
if isfield(opts,'solver')
    switch opts.solver
        case {'MengiOverton','HeWatson','simpleIteration','eig'}
        otherwise
            error('Unknown solver.')
    end
else
    opts.solver = 'MengiOverton';
end

% number of iterations to converge numerical radius
if ~isfield(opts,'nitmax')
    opts.nitmax = 500;
end

% standard tolerance
if ~isfield(opts,'tol')
    opts.tol    = 1e-6;
end

% use long-time mean if provided
if isfield(opts,'mean')
    if strcmp(opts.mean,'none')
    X_mean      = zeros(nVar,1);
    mean_name   = 'zero';    
    else
    X_mean      = opts.mean(1:nVar,:);
    mean_name   = 'provided long-time mean';    
    end
else
    X_mean      = squeeze(mean(X(:,1:nVar,:),1));
    mean_name   = 'data mean';
end

disp(['Mean                      : ' mean_name]);

% obtain frequency axis
[f,nFreq,idx,f_idx,f1_idx,f2_idx,f3_idx] = faxes(nDFT,dt,opts);

nTriads = length(idx);

% loop over number of blocks and generate Fourier realizations
disp(' ')
disp('Calculating temporal DFT')
disp('------------------------------------')
Q_hat = zeros(nFreq,nVar,nx,nBlks);
for iBlk = 1:nBlks
    % get time index for present block
    offset                  = min((iBlk-1)*(nDFT-nOvlp)+nDFT,nt)-nDFT;
    timeIdx                 = (1:nDFT) + offset;
    disp(['block ' num2str(iBlk) '/' num2str(nBlks) ' (' ...
        num2str(timeIdx(1)) ':' num2str(timeIdx(end)) ')'])
    for iVar = 1:nVar
        Q_blk          = bsxfun(@minus,squeeze(X(timeIdx,iVar,:)),squeeze(X_mean(iVar,:)));
        Q_blk          = bsxfun(@times,Q_blk,window);
        Q_blk_hat      = winWeight/nDFT*fft(Q_blk);
        Q_blk_hat      = fftshift(Q_blk_hat,1);
        Q_hat(:,iVar,:,iBlk) ...
                       = Q_blk_hat;
    end
end
clear X Q_blk Q_blk_hat X_mean

% loop over all triads and calculate CBMD
L      = nan(nFreq,nFreq);
if nargout>4
    T      = nan(nFreq,nFreq);
end
disp(' ')
disp('Calculating BMD')
disp('------------------------------------')

nState      = size(opts.s_idx,1);
nTerms      = size(opts.qr_idx,2)/2;
P           = zeros(2,nTriads,nx*nState);

if single_prec
    P       = single(P);
    Q_hat   = single(Q_hat);
end

weights     = repmat(weight,nState,1);
for i=1:nTriads
    disp(['(' num2str(f_idx(f1_idx(i))) ',' num2str(f_idx(f2_idx(i))) ',' num2str(f_idx(f3_idx(i))) ') (' num2str(i) '/' num2str(nTriads) ')'])

    Q_hat_s            = zeros(nState*nx,nBlks);
    Q_hat_qr           = zeros(nState*nx,nBlks);
    for j = 1:nState
        jj      = (j-1)*nx+1:j*nx;
        Q_hat_s(jj,:)  = squeeze(Q_hat(f3_idx(i),opts.s_idx(j),:,:));
        for k = 1:2:2*nTerms
        Q_hat_qr(jj,:) = Q_hat_qr(jj,:) + squeeze(Q_hat(f1_idx(i),opts.qr_idx(j,k),:,:)).*squeeze(Q_hat(f2_idx(i),opts.qr_idx(j,k+1),:,:));
        end
    end
    
    B                  = Q_hat_s'*bsxfun(@times,Q_hat_qr,weights)/nBlks;    
    
    % optimizer for x*Ax
    switch opts.solver
        case {'MengiOverton'}
            %  Mengi & Overton's algorithm
            [r,a]  = MengiOverton(B,opts.tol,opts.nitmax);
        case {'HeWatson'}
            %  He & Watson's sophisticated iteration
            [r,a]  = HeWatson(B,opts.tol,opts.nitmax);
        case {'simpleit'}
            %  Watson's simple iteration
            a      = rand(nBlks,1) + 1i*rand(nBlks,1); % random initial guess
            [r,a]  = simpleIteration(B,a);
        otherwise
            error('Unknown solver.')
    end
    
    % i+j component
    Psi           = Q_hat_s*a(:,1);
    Psi           = Psi/sqrt(Psi'*(Psi.*weights)); % normalize by inner product
    P(1,i,:)      = Psi;

    % i*j component
    Psi           = Q_hat_qr*a(:,1);
    Psi           = Psi/sqrt(Psi'*(Psi.*weights)); % normalize by inner product
    P(2,i,:)      = Psi;
    
    % mode bispectrum
    L(f1_idx(i),f2_idx(i),1) ...
                  = r;

    % energy transfer term
    if nargout>4
    T(f1_idx(i),f2_idx(i)) ...
                  = real((Q_hat_s*a)' * (Q_hat_qr*a))/nBlks;
    end
end
P   = reshape(P,[2 nTriads dim(3:end) nState]);
end    

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [window,weight,nOvlp,dt,nDFT,nBlks] = parser(nt,nx,varargin)
% PARSER Parser for BMD parameters

% read input arguments from cell array
window = []; weight = []; nOvlp = []; dt = [];
nvarargin = length(varargin);

if nvarargin >= 1
    window = varargin{1};
    if nvarargin >= 2
        weight   = varargin{2};
        if nvarargin >= 3
            nOvlp   = varargin{3};
            if nvarargin >= 4
                dt      = varargin{4};
            end
        end
    end
end

window = window(:); weight = weight(:);

% check arguments and determine default spectral estimation parameters
% window size and type
if isempty(window)
    nDFT        = 2^floor(log2(nt/5)); if nDFT>256, nDFT=256; end
    window      = hammwin(nDFT);
    window_name = 'Hamming';
elseif length(window)==1
    nDFT        = window;
    window      = hammwin(window);
    window_name = 'Hamming';
elseif length(window) == 2^nextpow2(length(window))
    nDFT        = length(window);
    window_name = 'user specified';
else
    nDFT        = length(window);
    window_name = 'user specified';
end

% block overlap
if isempty(nOvlp)
    nOvlp = floor(nDFT/2);
elseif nOvlp > nDFT-1
    error('Overlap too large.')
end

% time step between consecutive snapshots
if isempty(dt)
    dt = 1/nDFT;
end

% inner product weight
if isempty(weight)
    weight      = ones(nx,1);
    weight_name = 'uniform';
elseif numel(weight) ~= nx
    error('Weights must have the same spatial dimensions as data.');
else
    weight_name = 'user specified';
end

% number of blocks
nBlks = floor((nt-nOvlp)/(nDFT-nOvlp));

% test feasibility
if nDFT < 4 || nBlks < 2
    error('Spectral estimation parameters not meaningful.');
end

% display parameter summary
disp(' ')
disp('BMD parameters')
disp('------------------------------------')
disp(['No. of snaphots per block : ' num2str(nDFT)])
disp(['Block overlap             : ' num2str(nOvlp)])
disp(['No. of blocks             : ' num2str(nBlks)])
disp(['Windowing fct. (time)     : ' window_name])
disp(['Weighting fct. (space)    : ' weight_name])
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [window] = hammwin(N)
% HAMMWIN standard Hamming window of lenght N
window = 0.54-0.46*cos(2*pi*(0:N-1)/(N-1))';
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [w,z] = simpleIteration(A,z_0,tol)
% SIMPLEITERATION simple power iteration from He & Watson that is not
% guaranteed to find global optimum; small tolerences proposed in original
% paper tends to prevent convergence. 1e-8 works in most cases.
z       = z_0/sqrt(z_0'*z_0);
w       = Inf;
w_err   = Inf;
it_max  = 100;
it      = 0;
% tol   = 10*length(A)*eps*norm(A,1);
while w_err > tol
    
    w_old   = w;
    w       = z'*A*z;
    w_err   = abs(w-w_old);
    z       = w*A'*z + w'*A*z;
    z       = z/sqrt(z'*z);
    
    it      = it+1;
    if it>it_max, break, end
end
w       = z'*A*z;
% disp(['Watson's simple iteration required ' num2str(it) ' iterations.']);
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [w,z] = HeWatson(A,tol,nitmax)
% HEWATSON 'An Algorithm' from He & Watson (1997) that is guranteed to find
% the global optimum upon convergence
N       = size(A,1);
normA   = norm(A,1);
z       = rand(N,1) + 1i*rand(N,1);
lb      = 0;
ub      = normA;
Z       = zeros(N);
I       = eye(N);
S       = [A Z; Z I];

it  = 0;
while (ub-lb)>tol || it==0
    it = it + 1;
    
    [w,z]   = simpleIteration(A,z,tol);
    lb      = max(lb,abs(w));
    alpha   = lb + tol;
    R       = [2*alpha*I -A'; I Z];
    [V,D]   = eig(R,S);
    D       = diag(D);
    
    ucirc   = abs(abs(D)-1) < (sqrt(eps)*normA);
    if sum(ucirc)==0
        break
    elseif mod(it,100)==0
        disp(['He & Watson algorithm did not converge in ' num2str(it) ' iterations! Trying new initial guess...']);
        z       = rand(N,1) + 1i*rand(N,1);
    elseif it>=nitmax
        disp(['He & Watson algorithm did not converge in ' num2str(it) ' iterations!']);
        break
    else
        idx = find(ucirc==1);
        z   = V(end-N+1:end,idx(1));
    end
end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [w,z] = MengiOverton(A,tol,nitmax)
% MENGIOVERTON level-set algorithm from Mengi & Overton (2005) that is
% globally convergent
%
% B. Yeung (byeung@ucsd.edu)
% Last revision: 2023-08-16

N       = size(A,1);
normA   = norm(A,1);
Z       = zeros(N);
I       = eye(N);
S       = [A Z; Z I];

it = 0;
phi = 0;
while ~isempty(phi)
    w_temp = maxFOV(A,phi);
    [w,idx] = max(w_temp);
    phi_max = phi(idx);
    
    w = w*(1+tol);
    R       = [2*w*I -A'; I Z];
    [~,D]   = eig(R,S,'vector');
    isunimod   = abs(abs(D)-1) <= (sqrt(eps)*normA);
    Dunimod = D(isunimod);
    thetaprime = angle(Dunimod);
    theta = [];
    for i = 1:length(thetaprime)
        if abs(maxFOV(A,thetaprime(i))-w)<=sqrt(eps)*w
            theta = [theta; thetaprime(i)];
        end
    end
    theta = unique(theta);
    phi = [];
    for i=1:length(theta)
        lb = theta(i);
        if i<length(theta)
            ub = theta(i+1);
            mid = (lb+ub)/2;
        else
            ub = theta(1);
            mid = mod((lb+ub+2*pi)/2,2*pi);
        end
        if maxFOV(A,mid)>w
            phi = [phi; mid];
        end
    end
    it = it+1;
    if it>=nitmax
        disp(['Mengi & Overton algorithm did not converge in ' num2str(it) ' iterations!']);
        break
    end
end
B = A*exp(1i*phi_max);
H = (B+B')/2;
[V,D] = eig(H,'vector');
[~,idx] = max(abs(D));
z = V(:,idx);

% reconstruct complex w
w = z'*A*z;
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function lmax = maxFOV(A,theta)
% MAXFOV maximum field of value of matrix A at angle theta
ntheta = length(theta);
lmax = zeros(ntheta,1);
for i = 1:ntheta
    A_rot = A*exp(1i*theta(i));
    H = 0.5*(A_rot+A_rot');
    lmax(i) = max(abs(eig(H)));
end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [f,nFreq,idx,f_idx,f1_idx,f2_idx,f3_idx] = faxes(nDFT,dt,opts)
% FAXES obtain frequency axes and indices
f_idx = (0:nDFT-1);
if mod(nDFT,2)==0
    f_idx(nDFT/2+1:end)     = f_idx(nDFT/2+1:end)-nDFT;
else
    f_idx((nDFT+1)/2+1:end) = f_idx((nDFT+1)/2+1:end)-nDFT;
end
f_idx   = fftshift(f_idx);
f       = f_idx/dt/nDFT;
fNyq_idx= -f_idx(1);
nFreq   = numel(f_idx);
if isfield(opts,'nfreq')
    f_idx_max   = opts.nfreq;
else
    f_idx_max   = fNyq_idx;
end

region  = nan(nFreq,nFreq);
idx     = nan(nFreq^2,1);
f1_idx  = idx;
f2_idx  = idx;
f3_idx  = idx;
count   = 0;
for i=1:nFreq
    for j=1:nFreq
        f1plus2  = f_idx(i)+f_idx(j);
        if abs(f1plus2)<fNyq_idx && abs(f_idx(i))<=f_idx_max && abs(f_idx(j))<=f_idx_max
            if sum(opts.regions==1)>0 && f_idx(i)>=0 && f_idx(j)>=0 && f_idx(i)>=f_idx(j)            % region #1
                region(i,j)     = 1;
            end
            if sum(opts.regions==2)>0 && f_idx(i)>=0 && f_idx(j)<=0 && f_idx(i)>=abs(f_idx(j))       % region #2
                region(i,j)     = 2;
            end
            if sum(opts.regions==3)>0 && f_idx(i)>=0 && f_idx(j)<=0 && f_idx(i)<=abs(f_idx(j))       % region #3
                region(i,j)     = 3;
            end
            if sum(opts.regions==4)>0 && f_idx(i)<=0 && f_idx(j)<=0 && f_idx(i)>=(f_idx(j))          % region #4
                region(i,j)     = 4;
            end
            if sum(opts.regions==5)>0 && f_idx(i)<=0 && f_idx(j)<=0 && f_idx(i)<=f_idx(j)            % region #5
                region(i,j)     = 5;
            end
            if sum(opts.regions==6)>0 && f_idx(i)<=0 && f_idx(j)>=0 && abs(f_idx(i))>=f_idx(j)       % region #6
                region(i,j)     = 6;
            end
            if sum(opts.regions==7)>0 && f_idx(i)<=0 && f_idx(j)>=0 && abs(f_idx(i))<=f_idx(j)       % region #7
                region(i,j)     = 7;
            end
            if sum(opts.regions==8)>0 && f_idx(i)>=0 && f_idx(j)>=0 && f_idx(i)<=f_idx(j)            % region #8
                region(i,j)     = 8;
            end
        end
        
        if ~isnan(region(i,j))
            count           = count + 1;
            idx(count)      = sub2ind([nFreq nFreq],i,j);
            f1_idx(count)   = i;
            f2_idx(count)   = j;
            f3_idx(count)   = find(f_idx==f1plus2);
        end
    end
end
f1_idx  = f1_idx(1:count);
f2_idx  = f2_idx(1:count);
f3_idx  = f3_idx(1:count);
idx     = idx(1:count);
end