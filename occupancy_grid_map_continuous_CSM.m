classdef occupancy_grid_map_continuous_CSM < handle
    properties
        % map dimensions
        range_x = [-15, 20];
        range_y = [-25, 10];
        % sensor parameters
        z_max = 30;                 % max range in meters
        n_beams = 133;              % number of beams
        % grid map paremeters
        grid_size = 0.135;
        
        % Note: the alpha and beta here are not the alpha and beta in CSM
        alpha = 2 * 0.135;          % 2 * grid_size  
        beta = 2 * pi/133;          % 2 * pi/n_beams
        nn = 16;                    % number of nearest neighbor search
        map;                        % map!
        pose;                       % pose data
        scan;                       % laser scan data
        m_i = [];                   % cell i
        
        l = 0.2;
        sigma = 0.1;
        % -----------------------------------------------
        % To Do: 
        % prior initialization
        prior_alpha = 0.001;
        prior_beta  = 0.001; 
        % -----------------------------------------------
    end
    
    methods
        function obj = occupancy_grid_map_continuous_CSM(pose, scan)
            % class constructor
            % construct map points, i.e., grid centroids.
            x = obj.range_x(1):obj.grid_size:obj.range_x(2);
            y = obj.range_y(1):obj.grid_size:obj.range_y(2);
            [X,Y] = meshgrid(x,y);
            t = [X(:), Y(:)];
            % a simple KDtree data structure for map coordinates.
            obj.map.occMap = KDTreeSearcher(t);
            obj.map.size = size(t,1);
            
            % -----------------------------------------------
            % To Do: 
            % map parameter initialization such as map.alpha and map.beta
            obj.map.alpha = obj.prior_alpha*ones(obj.map.size,1);
            obj.map.beta  = obj.prior_beta*ones(obj.map.size,1);
            
            obj.map.mean     = zeros(obj.map.size,1);
            obj.map.variance = zeros(obj.map.size,1);
            % -----------------------------------------------
            
            % set robot pose and laser scan data
            obj.pose = pose;
            obj.pose.mdl = KDTreeSearcher([pose.x, pose.y]);
            obj.scan = scan;
        end
        
        function build_ogm(obj)
            % build occupancy grid map using the binary Bayes filter.
            % we first loop over all map cells, then for each cell, we find
            % N nearest neighbor poses to build the map. Note that this is
            % more efficient than looping over all poses and all map cells
            % for each pose which should be the case in online
            % (incremental) data processing.
            for i = 1:obj.map.size
                m = obj.map.occMap.X(i,:);
                idxs = knnsearch(obj.pose.mdl, m, 'K', obj.nn);
                if ~isempty(idxs)
                    for k = idxs
                        % pose k
                        pose_k = [obj.pose.x(k),obj.pose.y(k), obj.pose.h(k)];
                        if obj.is_in_perceptual_field(m, pose_k)
                            % laser scan at kth state; convert from
                            % cartesian to polar coordinates
                            [bearing, range] = cart2pol(obj.scan{k}(1,:), obj.scan{k}(2,:));
                            z = [range' bearing'];
                            
                            % -----------------------------------------------
                            % To Do: 
                            % update the sensor model in cell i
                            obj.continuous_counting_sensor_model(z,i);
                            % -----------------------------------------------
                        end
                    end
                end
                
                
                % -----------------------------------------------
                % To Do: 
                % update mean and variance for each cell i
                alpha_beta_sum = obj.map.alpha(i)+obj.map.beta(i);
                obj.map.mean(i) = obj.map.alpha(i)/alpha_beta_sum;
                obj.map.variance(i) = obj.map.alpha(i)*obj.map.beta(i)/...
                    (alpha_beta_sum^2*(alpha_beta_sum+1));
                % -----------------------------------------------
                
                
            end
        end
        
        function inside = is_in_perceptual_field(obj, m, p)
            % check if the map cell m is within the perception field of the
            % robot located at pose p.
            inside = false;
            d = m - p(1:2);
            obj.m_i.range = sqrt(sum(d.^2));
            obj.m_i.phi = wrapToPi(atan2(d(2),d(1)) - p(3));
            % check if the range is within the feasible interval
            if (0 < obj.m_i.range) && (obj.m_i.range < obj.z_max)
                % here sensor covers -pi to pi!
                if (-pi < obj.m_i.phi) && (obj.m_i.phi < pi)
                    inside = true;
                end
            end
        end
        
        function continuous_counting_sensor_model(obj, z, i)
            % -----------------------------------------------
            % To Do: 
            % implement the continuous counting sensor model
                        
             % find the nearest beam
            bearing_diff = abs(wrapToPi(z(:,2) - obj.m_i.phi));
            [bearing_min, k] = min(bearing_diff);
            
            if obj.m_i.range > min(obj.z_max, z(k,1) + obj.alpha/2) || bearing_min > obj.beta/2
                % do nothing. nothing needs to be updated
                
            elseif z(k,1) < obj.z_max && abs(obj.m_i.range - z(k,1)) < obj.alpha/2 
                % this means cell i is in the occupied region
                pos_cell_i = obj.polar2cartesian(obj.m_i.range,obj.m_i.phi);
                pos_beamEndPt = obj.polar2cartesian(z(k,1),z(k,2));
                distance = sqrt(sum((pos_beamEndPt-pos_cell_i).^2));
                ker = obj.kernel(distance);
                obj.map.alpha(i) = obj.map.alpha(i)+ker;
            
            elseif obj.m_i.range <  z(k,1) && z(k,1) < obj.z_max
                % this means cell i is the cone
                pos_cell_i = obj.polar2cartesian(obj.m_i.range,obj.m_i.phi);
                beamPt_ranges = [obj.m_i.range-obj.l, obj.m_i.range-obj.l/3, ...
                              obj.m_i.range+obj.l/3, obj.m_i.range+obj.l];
                ker_sum = 0;
                for beamPt_range = beamPt_ranges
                    pos_beamPt = obj.polar2cartesian(beamPt_range,z(k,2));
                    distance = sqrt(sum((pos_beamPt-pos_cell_i).^2));
                    ker = obj.kernel(distance);
                    ker_sum = ker_sum+ker;
                end
                obj.map.beta(i) = obj.map.beta(i) + ker_sum;
            end
            % -----------------------------------------------
        end
        
        function k = kernel (obj,d)
            if d < obj.l
                    k = obj.sigma * ((1/3 * (2 + cos(2*pi*d/obj.l)) * (1 - (d/obj.l))) + (1/(2*pi) * sin(2*pi*d/obj.l)));
                else
                    k = 0;
            end
        end
        
        function cart = polar2cartesian(~,r,th)
           cart = [r*cos(th),r*sin(th)]; 
        end
        
    end
end