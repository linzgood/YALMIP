function Fchance = modelchance(F,options,rec)

% Goes through all probability constraints and checks for cases where we
% can use analytic expressions.

% Find chance constraints
chanceDeclarations = find(is(F,'chance'));
if isempty(chanceDeclarations)
    Fchance = F;
    return
end

% Find variables with attached distributions
randomDeclarations = find(is(F,'random'));
if isempty(randomDeclarations)
    error('Chance constraints without any distributions');
end

if nargin < 2
    options = sdpsettings;
end
if nargin < 3
    % Keep track of recursive calls for print-outs
    rec = 0;
end

keep = ones(length(F),1);
keep(chanceDeclarations)=0;
randomVariables = extractRandomDefinitions(F(randomDeclarations));
if options.verbose
    if ~rec
        disp('***** Starting YALMIP chance constraint module. *******************')
    else
        disp(' - (recursive application of chance constraints)')
    end
    disp([' - Detected ' num2str(length(randomVariables)) ' distribution models.'])
end

[randomVariables,map] = mergeDistributions(randomVariables);
if options.verbose && length(map)>max(map)
    disp([' - Merged to ' num2str(length(randomVariables)) ' distribution models.'])
end

groupedChanceConstraints = groupchanceconstraints(F);

if options.verbose
    disp([' - Detected ' num2str(length(groupedChanceConstraints)) ' chance constraints.'])
end

[Fchance,eliminatedConstraints,recursive] = deriveChanceModel(groupedChanceConstraints,randomVariables,options);
Fchance = Fchance + F(find(keep)) + F(find(keep(~eliminatedConstraints)));
if recursive
    Fchance = modelchance(Fchance,options,1);
end
if ~rec
    disp('***** Modeling of chance constraints done. ************************')
end


function [Fchance,eliminatedConstraints,recursive] = deriveChanceModel(groupedChanceConstraints,randomVariables,options);



recursive = 0;
Fchance = [];
eliminatedConstraints = zeros(length(groupedChanceConstraints),1);

allwVars = [];
for i = 1:length(randomVariables)
    allwVars = [allwVars;getvariables(randomVariables{i}.variables)];
end

for uncertaintyGroup = 1:length(randomVariables)
    
    wVars = getvariables(randomVariables{uncertaintyGroup}.variables);
    
    for ic = 1:length(groupedChanceConstraints)
        if length(groupedChanceConstraints{ic})>1
            error('Joint chance constraint not supported');
        end
        if ~is(groupedChanceConstraints{ic},'elementwise')
            error('Only elementwise chance constraints supported')
        end
        X = sdpvar(groupedChanceConstraints{ic});
        if length(X)>1
            error('Only single elementwise chance constraints supported')
        end
        
        % Extract quadratic part, X = fX + X, where fx is other stuff
        [fX,X] = functionSeparation(X);
        
        allVars = depends(X);
        if ~isempty(intersect(wVars,allVars))
            xVars = setdiff(allVars,wVars);
            x = recover(xVars);
            w = recover(wVars);
            
            fail = 0;
            [A,cx,b,cw,fail] = quadraticDecomposition(X,x,w);
            
            % Remap to original ordering on variables in distribution
            % Base = full(getbase(randomVariables{uncertaintyGroup}.variables));
            % Base = Base(:,2:end);
            % [ii,jj,kk] = find(Base)
            %  cw = cw*Base;
            %  A = A*Base;
            
            % b(x) + c(x)'*w >= 0
            if isempty(b)
                b = 0;
            end
            b = b + fX;
            if ~isempty(cx)
                b = b + cx'*x;
            end
            c = cw';
            if ~isempty(A)
                c = c + A'*x;
            end
            
            newConstraint = [];
            if ~fail
                confidencelevel = struct(groupedChanceConstraints{ic}).clauses{1}.confidencelevel;
                if strcmp(func2str(randomVariables{uncertaintyGroup}.distribution.name),'random')
                    switch randomVariables{uncertaintyGroup}.distribution.parameters{1}
                        case 'moment'
                            newConstraint = momentChanceFilter(b,c,randomVariables{uncertaintyGroup}.distribution,confidencelevel,w,options);
                            printout(options.verbose,'moment',randomVariables{uncertaintyGroup}.distribution);
                            eliminatedConstraints(ic)=1;
                        case {'normal','normalm'}
                            newConstraint = normalChanceFilter(b,c,randomVariables{uncertaintyGroup}.distribution,confidencelevel,w,options);
                            printout(options.verbose,'exact',randomVariables{uncertaintyGroup}.distribution);
                            eliminatedConstraints(ic)=1;
                        case 'normalf'
                            newConstraint = normalfactorizedChanceFilter(b,c,randomVariables{uncertaintyGroup}.distribution,confidencelevel,w,options);
                            printout(options.verbose,'exact',randomVariables{uncertaintyGroup}.distribution);
                            eliminatedConstraints(ic)=1;
                        otherwise
                            switch options.chance.method
                                case 'chebyshev'
                                    newConstraint = sampledchebyshevChanceFilter(b,c,randomVariables{uncertaintyGroup}.distribution,confidencelevel,w,options);
                                case 'moment'
                                    newConstraint = sampledmomentChanceFilter(b,c,randomVariables{uncertaintyGroup}.distribution,confidencelevel,w,options);
                                case 'markov'
                                    newConstraint =  sampledmarkovChanceFilter(b,c,randomVariables{uncertaintyGroup}.distribution,confidencelevel,w,options);
                                case 'chernoff'
                                    newConstraint =  sampledchernoffChanceFilter(b,c,randomVariables{uncertaintyGroup}.distribution,confidencelevel,w,options);
                                otherwise
                                    error('Chance modeling approach not recognized');
                            end
                            printout(options.verbose,options.chance.method,randomVariables{uncertaintyGroup}.distribution);
                            eliminatedConstraints(ic)=1;
                    end
                else
                    switch options.chance.method
                        case 'chebyshev'
                            newConstraint = sampledchebyshevChanceFilter(b,c,randomVariables{uncertaintyGroup}.distribution,confidencelevel,w,options);
                        case 'moment'
                            newConstraint = sampledmomentChanceFilter(b,c,randomVariables{uncertaintyGroup}.distribution,confidencelevel,w,options);
                        case 'markov'
                            newConstraint =  sampledmarkovChanceFilter(b,c,randomVariables{uncertaintyGroup}.distribution,confidencelevel,w,options);
                        case 'chernoff'
                            newConstraint =  sampledchernoffChanceFilter(b,c,randomVariables{uncertaintyGroup}.distribution,confidencelevel,w,options);
                        otherwise
                            error('Chance modeling approach not recognized');
                    end
                    printout(options.verbose,options.chance.method,randomVariables{uncertaintyGroup}.distribution);
                    eliminatedConstraints(ic)=1;
                end
            end
            if ~isempty(newConstraint)
                if ~isempty(intersect(depends(newConstraint),allwVars))
                    % New uncertainties popped up,i.e. parameters in a
                    % distribution, are distributions them selves
                    Fchance = [Fchance, probability(newConstraint)>=confidencelevel];
                    recursive = 1;
                else
                    Fchance = [Fchance, newConstraint];
                end
            end
        end
    end
end

function [AAA,ccc,b,c_wTbase,fail] = quadraticDecomposition(X,x,w)
b = [];
A = [];
% Some pre-calc
xw = [x;w];
fail = 0;
xind = find(ismembc(getvariables(xw),getvariables(x)));
wind = find(ismembc(getvariables(xw),getvariables(w)));
[Qs,cs,fs,dummy,nonquadratic] = vecquaddecomp(X,xw);
c_wTbase = [];
AAA = [];
ccc = [];
for i = 1:length(X)
    Q = Qs{i};
    c = cs{i};
    f = fs{i};
    if nonquadratic
        error('Constraints can be at most quadratic, with the linear term uncertain');
    end
    Q_ww = Q(wind,wind);
    if nnz(Q_ww)>0
        fail = 1;
        return
    end
    Q_xw = Q(xind,wind);
    Q_xx = Q(xind,xind);
    c_x = c(xind);
    c_w = c(wind);
    
    %b = [b;f + c_w'*w];
    %A = [A;-c_x'-w'*2*Q_xw'];
    % A = [A -c_x-2*Q_xw*w];
    AAA = [AAA;sparse(2*Q_xw)];
    ccc = [ccc;sparse(c_x)];
    b = [b;f+x'*Q_xx*x];
    c_wTbase = [c_wTbase;c_w'];
end




function printout(verbose,method,distribution)

if verbose
    if strcmpi(func2str(distribution.name),'random')
        disp([' - Using ''' method '''-filter on constraint with ''' distribution.parameters{1} ''' distribution']);
    else
        disp([' - Using ''' method '''-filter on constraint with data created by @' distribution.name']);
    end
end