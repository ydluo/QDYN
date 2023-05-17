!Module for derivs
! SEISMIC reference:
! [VdE] Van den Ende et al. (subm.), Tectonophysics

module derivs_all

  use problem_class
  implicit none

  type(problem_type), pointer :: odepb

  private

  public :: derivs, derivs_rk45
  public :: odepb


contains


!====================Subroutine derivs===========================
!-------Compute theta, vslip and time deriv for one time step----
!-------Call rdft in compute_stress : real DFT-------------------
!----------------------------------------------------------------

subroutine derivs(time,yt,dydt,pb)

  use fault_stress, only : compute_stress
  use friction, only : dtheta_dt, RSF_derivs, compute_velocity_RSF
  use friction_cns, only : compute_velocity, CNS_derivs
  use diffusion_solver, only : update_PT
  use utils, only : pack, unpack

  type(problem_type), intent(inout) :: pb
  double precision, intent(in) :: time, yt(pb%neqs*pb%mesh%nn)
  double precision, intent(out) :: dydt(pb%neqs*pb%mesh%nn)

  double precision, dimension(pb%mesh%nn) :: theta, theta2, sigma, tau, v
  double precision, dimension(pb%mesh%nn) :: main_var, dmain_var, slip, dslip
  double precision, dimension(pb%mesh%nn) :: dsigma_dt, dtau_dt, dth_dt, dth2_dt
  double precision, dimension(pb%mesh%nn) :: dV_dtau, dV_dtheta
  double precision, dimension(pb%mesh%nn) :: tau_y, dP_dt, dV_dP
  double precision, dimension(pb%mesh%nn) :: dummy1, dummy2
  double precision :: dtau_per, dt

  logical :: vary_sigma = .false.

  ! SEISMIC: initialise vectors to zero. If unitialised, each compiler
  ! may produce different results depending on its conventions
  tau = 0d0
  dtau_dt = 0d0
  dsigma_dt = 0d0
  dP_dt = 0d0
  dV_dP = 0d0
  dummy1 = 0d0
  dummy2 = 1d0
  tau_y = 0d0

  ! Check if the normal stress is updated
  vary_sigma = (pb%features%tp == 1) .or. (pb%features%stress_coupling == 1)

  call unpack(yt, theta, main_var, sigma, theta2, slip, pb)

  ! SEISMIC: when thermal pressurisation is requested, update P and T,
  ! then calculate effective stress sigma_e = sigma - P
  if (pb%features%tp == 1) then
    dt = time - pb%t_prev
    ! Shear heating rate (= shear stress x shear strain rate)
    tau_y = pb%tau * pb%v / (2 * pb%tp%w)
    if (pb%i_rns_law == 3) then
      ! CNS model uses porosity
      call update_PT(tau_y, pb%dtheta_dt, pb%theta, pb%v, dt, pb)
    else
      ! Replace porosity for dummies when using RSF
      call update_PT(tau_y, dummy1, dummy2, pb%v, dt, pb)
    endif
    sigma = sigma - pb%P
    dP_dt = pb%tp%dP_dt
  endif

  if (pb%i_rns_law == 3) then
    ! SEISMIC: the CNS model is solved for stress, not for velocity, so we
    ! compute the velocity and use that to compute dtau_dt, which is stored
    ! in dydt(2::pb%neqs). tau is stored as yt(2::pb%neqs). The system of
    ! ordinary differential equations is then solved in the same way as with
    ! the rate-and-state formulation. See [VdE], Section 3.2

    tau = main_var

    ! The subroutine below calculates the slip velocity, time-derivatives of
    ! the porosity (theta), and partial derivatives required for radiation
    ! damping. These operations are combined into one subroutine for efficiency
    call CNS_derivs(v, dth_dt, dth2_dt, dV_dtau, dV_dtheta, dV_dP, tau, &
                    sigma, theta, theta2, pb)
  else
    ! SEISMIC: for the classical rate-and-state model formulation, the slip
    ! velocity is stored in yt(2::pb%neqs), and tau is not used (set to zero)
    tau = main_var
    v = compute_velocity_RSF(tau, sigma, theta, pb)

    call RSF_derivs(dV_dtau, dV_dtheta, dV_dP, v, theta, tau, sigma, pb)
    ! SEISMIC: calculate time-derivative of state variable (theta)
    call dtheta_dt(v, tau, sigma, theta, theta2, dth_dt, dth2_dt, pb)
  endif

  ! compute shear stress rate from elastic interactions, for 0D, 1D & 2D
  ! SEISMIC: note the use of v instead of yt(2::pb%neqs)
  call compute_stress(dtau_dt, dsigma_dt, pb%kernel, v - pb%v_pl)

  !YD we may want to modify this part later to be able to
  !impose more complicated loading/pertubation
  !functions involved: problem_class/problem_type; input/read_main
  !                    initialize/init_field;  derivs_all/derivs
  ! periodic loading
  dtau_per = pb%Omper * pb%Aper * cos(pb%Omper*time)

  ! Rate of change of slip is simply the velocity
  dslip = v

  ! SEISMIC: calculate radiation damping. For rate-and-state, dmu_dv and
  ! dmu_dtheta contain the partial derivatives of friction to V and theta,
  ! respectively. For the CNS model, these variables contain the partials of
  ! velocity to shear stress (dV/dtau) and velocity to porosity (dV/dtheta),
  ! respectively. For compatibility, the names of these variables are not
  ! changed.
  ! An additional component is added When thermal pressurisation is requested,
  ! to include the change in pressure (and effective normal stress). This
  ! component is initiated as zero, but updated when TP is requested

   ! SEISMIC: the total dtau_dt results from the slip deficit and
   ! periodic loading, which is stored in dydt(2::pb%neqs)
   ! Damping is included from rewriting the following expression:
   ! dtau/dt = k(Vlp - Vs) - eta*(dV/dtau * dtau/dt + dV/dtheta * dtheta/dt)
   ! Rearrangement gives:
   ! dtau/dt = ( k[Vlp - Vs] - eta*dV/dtheta * dtheta/dt)/(1 + eta*dV/dtau)
   ! See [VdE], Section 3.2
   dmain_var =  (dtau_dt + dtau_per - pb%zimpedance * &
                (dV_dtheta * dth_dt + dV_dP * dP_dt)) / &
                (1 + pb%zimpedance * dV_dtau)

   call pack(dydt, dth_dt, dmain_var, dsigma_dt, dth2_dt, dslip, pb)

end subroutine derivs


!===============================================================================
! SEISMIC: the subroutine derivs_rk45 is a wrapper that interfaces between
! derivs and the Runge-Kutta-Fehlberg solver routine
!===============================================================================
subroutine derivs_rk45(time, yt, dydt)
  double precision :: time
  double precision :: yt(*)
  double precision :: dydt(*)

  call derivs(time,yt,dydt,odepb)

end subroutine derivs_rk45

end module derivs_all
