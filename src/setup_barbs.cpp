#include "setup.hpp"

// Feather barb/barbule microscale periodic unit cell: flow through the cell
// (+z) driven by a pressure drop. Active only if BARBS_SETUP is defined in
// defines.hpp (the default main_setup() in setup.cpp is then disabled).
//
// Required extensions in defines.hpp:
//   #define BARBS_SETUP
//   #define VOLUME_FORCE        (pressure drop is applied as an equivalent body
//   force in the periodic domain) #define TRT                 (instead of SRT:
//   much less viscosity-dependent bounce-back permeability) FP16S / FP16C
//   disabled      (use FP32: lattice velocities and forces are very small at
//   this Reynolds number) SUBGRID disabled, EQUILIBRIUM_BOUNDARIES not needed,
//   BENCHMARK disabled
//
// Geometry: ./stl/FreeCAD_BarbBarbuleMicroscale_SOLID_EXPORT.stl (closed solid,
// mm, Z-trimmed export)
//   domain box [mm]: x 0 -> 0.26, y 0 -> 0.2, z 0 -> 0.5; STL vertices are used
//   as-is (no auto-rescale/reposition) x/y faces: periodic (default in
//   FluidX3D); z faces: periodic, flow driven by f_z = dP/Lz
#ifdef BARBS_SETUP
void main_setup() {
	// ###################################################### user parameters
	// ######################################################
	float dx_um =
		2.0f; // lattice spacing [micrometers]; choose 20/k um (2, 1, 0.5, 0.4,
			  // 0.25, ...) so Nx, Ny, Nz are integers
	if (const char *env_dx = std::getenv("FLUIDX3D_DX_UM")) {
		const float parsed = to_float(string(env_dx), 0.0f);
		if (parsed > 0.0f)
			dx_um = parsed;
	}
	if (!main_arguments.empty()) {
		const float parsed = to_float(main_arguments[0], 0.0f);
		if (parsed > 0.0f) {
			dx_um = parsed;
			main_arguments.erase(main_arguments.begin());
		}
	}
	uint Dz = (dx_um <= 0.25f) ? 8u : 1u; // Dz=8 for dx=0.25um (15.2 GB fi buffer/domain < 20 GB OpenCL limit)
	if (const char *env_dz = std::getenv("FLUIDX3D_DZ")) {
		const uint parsed_dz = to_uint(string(env_dz));
		if (parsed_dz >= 1u)
			Dz = parsed_dz;
	}
	if (Dz > 1u && main_arguments.empty()) {
		for (uint d = 0u; d < Dz; d++) {
			main_arguments.push_back(to_string(d < (Dz / 2u) ? 0u : 1u));
		}
	}
	const float dP_Pa = 13.5f;	 // pressure drop across the top and bottom faces
								 // (periodic length Lz) [Pa]
	const float tau = 0.8f;		 // LBM relaxation time (nu_lb = (tau-0.5)/3); keep
								 // constant across the mesh sensitivity study
	const float rho_si = 1.2f;	 // air density [kg/m^3]
	const float nu_si = 1.5e-5f; // air kinematic viscosity [m^2/s]
	const ulong min_steps =
		5000ull;						// minimum number of time steps before convergence is checked
	const ulong max_steps = 2000000ull; // hard limit of time steps
	const uint check_interval =
		2000u;						// time steps between flow-rate evaluations
	const float conv_tol = 1.0e-4f; // converged if relative change of flow rate
									// between evaluations is below this
	// ################################ domain boundaries and solid extent from
	// FreeCAD (barbs_boundaries_ztrim.json) [mm]
	// ################################
	const float Lx_mm = 0.26f, Ly_mm = 0.2f,
				Lz_mm = 0.5f; // domain boundaries: x_min=y_min=z_min=0,
							  // x_max=0.26, y_max=0.2, z_max=0.5
	const float solid_zmin_mm = 0.124875f,
				solid_zmax_mm =
					0.375126f; // solid occupies z in [0.124875, 0.375126];
							   // nothing touches z_min/z_max
	const float cad_solid_volume_mm3 =
		0.0015551f; // CAD solid volume (porosity 0.9402) for voxelization check
	// ########################################################################################################################################

	const float dx_mm = dx_um * 1.0e-3f;
	const uint Nx = (uint)(Lx_mm / dx_mm + 0.5f),
			   Ny = (uint)(Ly_mm / dx_mm + 0.5f),
			   Nz = (uint)(Lz_mm / dx_mm + 0.5f);
	if (fabs(Lx_mm / dx_mm - (float)Nx) > 1.0e-3f ||
		fabs(Ly_mm / dx_mm - (float)Ny) > 1.0e-3f ||
		fabs(Lz_mm / dx_mm - (float)Nz) > 1.0e-3f)
		print_warning("dx does not divide the domain into an integer number of "
					  "cells; the periodic cell will be slightly distorted.");

	// unit conversion: 1 cell = dx, rho_lb = 1, dt from nu_lb = nu_si*dt/dx^2
	const float dx_si = dx_um * 1.0e-6f;
	const float nu_lb = (tau - 0.5f) / 3.0f;
	const float dt_si = nu_lb * sq(dx_si) / nu_si;
	units.set_m_kg_s(
		dx_si, rho_si * cb(dx_si), dt_si); // unit_m, unit_kg, unit_s
	const float Lz_si = Lz_mm * 1.0e-3f;
	const float f_si =
		dP_Pa / Lz_si; // force per volume [kg/(m*s)^2] equivalent to dP over
					   // the periodic length Lz
	const float fz = units.f(f_si);

	print_info("Domain: " + to_string(Nx) + " x " + to_string(Ny) + " x " +
		to_string(Nz) + " cells = " +
		to_string((double)Nx * (double)Ny * (double)Nz * 1.0e-6, 1u) +
		" M cells");
	print_info("dx = " + to_string(dx_um, 3u) + " um, dt = " +
		to_string(dt_si * 1.0e9f, 3u) + " ns, tau = " + to_string(tau, 3u) +
		", nu_lb = " + to_string(nu_lb, 4u));
	print_info("dP = " + to_string(dP_Pa, 2u) + " Pa over Lz = " +
		to_string(Lz_mm, 3u) + " mm -> f_z = " + to_string(f_si, 1u) +
		" N/m^3 = " + to_string(fz, 8u) + " (LBM units)");
	print_info("Boundary planes [mm]: x " + to_string(0.0f, 3u) + " | " +
		to_string(Lx_mm, 3u) + "  y " + to_string(0.0f, 3u) + " | " +
		to_string(Ly_mm, 3u) + "  z " + to_string(0.0f, 3u) + " | " +
		to_string(Lz_mm, 3u) + "  (cells: x 0 | " + to_string(Nx) + "  y 0 | " +
		to_string(Ny) + "  z 0 | " + to_string(Nz) + ")");

	LBM lbm(
		Nx, Ny, Nz, 1u, 1u, Dz, nu_lb, 0.0f, 0.0f, fz); // periodic in x, y, z by default

	// ###################################################### define geometry
	// ###################################################### STL is in mm and
	// already positioned in the domain box: scale to cells (1/dx_mm), offset 0
	// -> no auto-rescale/reposition
	const Mesh *mesh = read_stl(get_exe_path() +
			"../stl/FreeCAD_BarbBarbuleMicroscale_SOLID_EXPORT.stl",
		1.0f / dx_mm, float3x3(1.0f), float3(0.0f));
	print_info("STL bounding box [cells]: (" + to_string(mesh->pmin.x, 1u) +
		", " + to_string(mesh->pmin.y, 1u) + ", " +
		to_string(mesh->pmin.z, 1u) + ") -> (" + to_string(mesh->pmax.x, 1u) +
		", " + to_string(mesh->pmax.y, 1u) + ", " +
		to_string(mesh->pmax.z, 1u) +
		"); expected z: " + to_string(solid_zmin_mm / dx_mm, 1u) + " -> " +
		to_string(solid_zmax_mm / dx_mm, 1u));
	lbm.flags.write_to_device();
	lbm.voxelize_mesh_on_device(
		mesh, TYPE_S); // solid barbs/barbules: halfway bounce-back
	delete mesh;
	lbm.flags.read_from_device();

	ulong solid_cells = 0ull;
	for (ulong n = 0ull; n < lbm.get_N(); n++)
		solid_cells += (lbm.flags[n] & TYPE_S) ? 1ull : 0ull;
	const double solid_volume_mm3 = (double)solid_cells * cb((double)dx_mm);
	print_info("Voxelized solid volume = " + to_string(solid_volume_mm3, 6u) +
		" mm^3 vs CAD " + to_string(cad_solid_volume_mm3, 6u) +
		" mm^3 (difference " +
		to_string(
			100.0 * (solid_volume_mm3 / (double)cad_solid_volume_mm3 - 1.0),
			2u) +
		" %)");
	if (fabs(solid_volume_mm3 / (double)cad_solid_volume_mm3 - 1.0) > 0.05)
		print_warning("Voxelized solid volume differs >5% from CAD: mesh too "
					  "coarse, thin features lost, or STL not watertight.");

	// ###################################################### flow rate probes
	// ###################################################### measure the flow
	// rate through x-y planes in the clear fluid below and above the solid (and
	// one inside it); all must agree at steady state
	const uint z_below = (uint)(0.5f * solid_zmin_mm / dx_mm),
			   z_mid = (uint)(0.5f * (solid_zmin_mm + solid_zmax_mm) / dx_mm),
			   z_above = (uint)(0.5f * (solid_zmax_mm + Lz_mm) / dx_mm);
	const float layer_t_si = (solid_zmax_mm - solid_zmin_mm) *
		1.0e-3f;								   // barb layer thickness [m] for the permeability definition
	const float area_si = Lx_mm * Ly_mm * 1.0e-6f; // plane area [m^2]
	const float mu_si = rho_si * nu_si;
	const auto plane_flow_rate_lb =
		[&](const uint z) { // sum of u_z over all cells of an x-y plane in LBM
							// units (solid cells have u=0)
			double sum = 0.0;
			for (uint y = 0u; y < Ny; y++)
				for (uint x = 0u; x < Nx; x++)
					sum += (double)lbm.u.z[lbm.index(x, y, z)];
			return sum;
		};

	// ###################################################### run simulation
	// ######################################################
	const string conv_dat = get_exe_path() + "export/convergence.dat";
	create_folder(conv_dat);
	std::ofstream conv_file(conv_dat, std::ios::out | std::ios::trunc);
	conv_file << "# step t_us Q_mm3_s U_sup_m_s K_layer_um2 dQ_over_Q Q_above_over_below Q_mid_over_below\n"
			  << std::flush;

	lbm.run(0u, max_steps); // initialize
	double Q_old = 0.0, Q_below = 0.0, Q_mid = 0.0, Q_above = 0.0,
		   rel_change = 1.0;
	while (lbm.get_t() < max_steps) {
		lbm.run(check_interval, max_steps);
		lbm.u.read_from_device();
		Q_below = plane_flow_rate_lb(z_below);
		Q_mid = plane_flow_rate_lb(z_mid);
		Q_above = plane_flow_rate_lb(z_above);
		rel_change =
			Q_below != 0.0 ? fabs(Q_below - Q_old) / fabs(Q_below) : 1.0;
		Q_old = Q_below;
		const float Q_step_si = units.si_Q((float)Q_below);
		const float U_si = Q_step_si / area_si; // superficial velocity [m/s]
		const float K_step_um2 = (mu_si * U_si * layer_t_si / dP_Pa) * 1.0e12f;
		const double t_us = (double)lbm.get_t() * (double)dt_si * 1.0e6;
		conv_file << lbm.get_t() << " " << t_us << " " << (Q_step_si * 1.0e9f) << " "
				  << U_si << " " << K_step_um2 << " " << rel_change << " "
				  << (Q_above / Q_below) << " " << (Q_mid / Q_below) << std::endl;
		print_info("t = " + to_string(lbm.get_t()) +
			": U_sup = " + to_string(U_si, 6u) +
			" m/s, dQ/Q = " + to_string((float)rel_change, 6u) +
			", Q_above/Q_below = " + to_string((float)(Q_above / Q_below), 5u));
		if (lbm.get_t() >= min_steps && rel_change < conv_tol)
			break;
	}
	conv_file.close();

	// ###################################################### results
	// ######################################################
	const float Q_si =
		units.si_Q((float)Q_below);		// volume flow rate through the cell [m^3/s]
	const float U_sup = Q_si / area_si; // superficial (Darcy) velocity [m/s]
	const float K_layer = mu_si * U_sup * layer_t_si /
		dP_Pa; // Darcy permeability of the barb layer [m^2]
			   // (dP across layer thickness)
	const float dP_over_tU = dP_Pa /
		(layer_t_si * U_sup); // = mu/K + rho*beta*U (Darcy-Forchheimer), for
							  // fitting over several dP
	print_info("RESULT: Q = " + to_string(Q_si * 1.0e9f, 6u) +
		" mm^3/s, U_sup = " + to_string(U_sup, 6u) +
		" m/s, K_layer = " + to_string(K_layer * 1.0e12f, 6u) +
		" um^2, dP/(t*U) = " + to_string(dP_over_tU, 1u) + " kg/(m^3*s)");
	const string csv = get_exe_path() + "export/barbs_results.csv";
	create_folder(csv);
	const bool csv_exists = std::ifstream(csv).good();
	std::ofstream file(
		csv, std::ios::out | std::ios::app); // append: run several dP values /
											 // meshes into the same file
	if (!csv_exists)
		file << "dx_um,Nx,Ny,Nz,tau,dP_Pa,steps,converged,Q_m3_s,U_sup_m_s,Q_"
				"above_over_below,Q_mid_over_below,K_layer_m2,dP_over_tU\n";
	file << dx_um << "," << Nx << "," << Ny << "," << Nz << "," << tau << ","
		 << dP_Pa << "," << lbm.get_t() << ","
		 << (rel_change < conv_tol ? 1 : 0) << "," << Q_si << "," << U_sup
		 << "," << (Q_above / Q_below) << "," << (Q_mid / Q_below) << ","
		 << K_layer << "," << dP_over_tU << "\n";
	file.close();

	// ###################################################### ParaView-ready VTK export
	// ######################################################
	// Write flags as CELL_DATA on (Nx+1)x(Ny+1)x(Nz+1) grid (with origin shifted by
	// -0.5*dx so every solid lattice site is a true 1x1x1 voxel cell aligned with u),
	// and write u as POINT_DATA with "VECTORS Velocity float" header.
	{
		const string export_dir = get_exe_path() + "export/";
		const float spacing = units.si_x(1.0f);
		const ulong N_total = (ulong)Nx * (ulong)Ny * (ulong)Nz;
		const uint chunk_size_MB = 4u * thread::hardware_concurrency();

		// 1. Export flags-<step>.vtk as CELL_DATA (SCALARS data unsigned_char 1)
		lbm.flags.read_from_device();
		const string flags_filename = create_file_extension(
			default_filename(export_dir, "flags", ".vtk", lbm.get_t()), ".vtk");
		const float3 flags_origin = spacing *
			float3(-0.5f * (float)Nx, -0.5f * (float)Ny, -0.5f * (float)Nz);
		const string flags_header =
			"# vtk DataFile Version 3.0\nFluidX3D " +
			flags_filename.substr(flags_filename.rfind('/') + 1) +
			"\nBINARY\nDATASET STRUCTURED_POINTS\n"
			"DIMENSIONS " + to_string(Nx + 1u) + " " + to_string(Ny + 1u) + " " + to_string(Nz + 1u) + "\n"
			"ORIGIN " + to_string(flags_origin.x) + " " + to_string(flags_origin.y) + " " + to_string(flags_origin.z) + "\n"
			"SPACING " + to_string(spacing) + " " + to_string(spacing) + " " + to_string(spacing) + "\n"
			"CELL_DATA " + to_string(N_total) + "\n"
			"SCALARS data unsigned_char 1\nLOOKUP_TABLE default\n";
		{
			const ulong chunk_elements = (1048576ull * (ulong)chunk_size_MB) / sizeof(uchar);
			const ulong chunks = N_total / chunk_elements,
						chunk_remainder = N_total % chunk_elements;
			uchar *buf = new uchar[chunk_elements];
			create_folder(flags_filename);
			std::ofstream f_out(flags_filename, std::ios::out | std::ios::binary);
			f_out.write(flags_header.c_str(), flags_header.length());
			for (ulong c = 0ull; c < chunks + 1ull; c++) {
				const ulong N_chunk = c < chunks ? chunk_elements : chunk_remainder;
				if (N_chunk == 0ull)
					break;
				parallel_for(N_chunk, [&](ulong i) {
					buf[i] = reverse_bytes((uchar)((lbm.flags[c * chunk_elements + i] & TYPE_S) ? 1u : 0u));
				});
				f_out.write((char *)buf, N_chunk * sizeof(uchar));
			}
			f_out.close();
			delete[] buf;
			print_info("File \"" + flags_filename + "\" saved (ParaView CELL_DATA voxel format).");
		}

		// 2. Export u-<step>.vtk as POINT_DATA (VECTORS Velocity float)
		lbm.u.read_from_device();
		const string u_filename = create_file_extension(
			default_filename(export_dir, "u", ".vtk", lbm.get_t()), ".vtk");
		const float3 u_origin = spacing *
			float3(0.5f - 0.5f * (float)Nx, 0.5f - 0.5f * (float)Ny, 0.5f - 0.5f * (float)Nz);
		const string u_header =
			"# vtk DataFile Version 3.0\nFluidX3D " +
			u_filename.substr(u_filename.rfind('/') + 1) +
			"\nBINARY\nDATASET STRUCTURED_POINTS\n"
			"DIMENSIONS " + to_string(Nx) + " " + to_string(Ny) + " " + to_string(Nz) + "\n"
			"ORIGIN " + to_string(u_origin.x) + " " + to_string(u_origin.y) + " " + to_string(u_origin.z) + "\n"
			"SPACING " + to_string(spacing) + " " + to_string(spacing) + " " + to_string(spacing) + "\n"
			"POINT_DATA " + to_string(N_total) + "\n"
			"VECTORS Velocity float\n";
		{
			const float unit_u = units.si_u(1.0f);
			const ulong chunk_elements = (1048576ull * (ulong)chunk_size_MB) / (3ull * sizeof(float));
			const ulong chunks = N_total / chunk_elements,
						chunk_remainder = N_total % chunk_elements;
			float *buf = new float[chunk_elements * 3ull];
			create_folder(u_filename);
			std::ofstream u_out(u_filename, std::ios::out | std::ios::binary);
			u_out.write(u_header.c_str(), u_header.length());
			for (ulong c = 0ull; c < chunks + 1ull; c++) {
				const ulong N_chunk = c < chunks ? chunk_elements : chunk_remainder;
				if (N_chunk == 0ull)
					break;
				parallel_for(N_chunk, [&](ulong i) {
					const ulong idx = c * chunk_elements + i;
					buf[i * 3ull + 0ull] = reverse_bytes(unit_u * lbm.u.x[idx]);
					buf[i * 3ull + 1ull] = reverse_bytes(unit_u * lbm.u.y[idx]);
					buf[i * 3ull + 2ull] = reverse_bytes(unit_u * lbm.u.z[idx]);
				});
				u_out.write((char *)buf, N_chunk * 3ull * sizeof(float));
			}
			u_out.close();
			delete[] buf;
			print_info("File \"" + u_filename + "\" saved (ParaView VECTORS Velocity format).");
		}
	}
} // main_setup()
#endif // BARBS_SETUP
